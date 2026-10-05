/**
 * Wrapper na on-device Web Speech API (Chrome 133+).
 *
 * Dwie rzeczy, które sprawiają, że surowe API nie nadaje się do transkrypcji
 * długiej rozmowy i które ta klasa załatwia:
 *
 *  1. Rozpoznawanie samo się kończy po dłuższej ciszy (`onend`) — trzeba je
 *     wznawiać, inaczej transkrypcja cicho umiera w połowie spotkania.
 *  2. Po wznowieniu `resultIndex` startuje od zera, więc identyfikatory
 *     wyników z różnych przebiegów kolidują. Stąd `epoch` w kluczu.
 *
 * `processLocally = true` wymusza model na urządzeniu — audio nie opuszcza
 * przeglądarki. Bez tego Chrome wysyła je na serwery Google.
 */

/** Błędy, po których po prostu wznawiamy — to normalny bieg rzeczy. */
const BENIGN_ERRORS = new Set(['no-speech', 'aborted', 'audio-capture']);

/** Błędy, których restart nie naprawi — trzeba zmienić konfigurację. */
export const FATAL_ERRORS = new Set(['not-allowed', 'service-not-allowed', 'language-not-supported']);

/** Konstruktor SpeechRecognition, jeśli przeglądarka go ma. */
export function speechRecognitionCtor(scope = globalThis) {
  return scope.SpeechRecognition ?? scope.webkitSpeechRecognition ?? null;
}

export function isSupported(scope = globalThis) {
  return speechRecognitionCtor(scope) !== null;
}

/**
 * Stan pakietu językowego dla rozpoznawania lokalnego.
 * @returns {Promise<'available'|'downloadable'|'downloading'|'unavailable'|'unsupported'>}
 */
export async function availability(langs, scope = globalThis) {
  const Ctor = speechRecognitionCtor(scope);
  if (!Ctor?.available) return 'unsupported';
  try {
    return await Ctor.available({ langs: [].concat(langs), processLocally: true });
  } catch {
    return 'unsupported';
  }
}

/**
 * Pobiera pakiet językowy na urządzenie. Potrafi trwać — to setki MB modelu,
 * którymi zarządza Chrome, nie my.
 * @returns {Promise<boolean>}
 */
export async function install(langs, scope = globalThis) {
  const Ctor = speechRecognitionCtor(scope);
  if (!Ctor?.install) return false;
  try {
    return await Ctor.install({ langs: [].concat(langs), processLocally: true, quality: 'conversation' });
  } catch {
    return false;
  }
}

/**
 * Wybiera tryb rozpoznawania na podstawie tego, co realnie jest dostępne.
 *
 * Lokalny model to komponent SODA Chrome'a — ten sam, którego używają „Napisy
 * na żywo". Dopóki użytkownik ich nie włączy, `available()` zwraca
 * 'downloadable', a `start()` z processLocally kończy się błędem
 * `language-not-supported`. `install()` też potrafi zwrócić false mimo gestu
 * użytkownika, więc nie da się na nim polegać.
 *
 * @returns {Promise<{processLocally: boolean, availability: string, reason: string}>}
 */
export async function resolveMode({ lang, allowCloud = false, scope = globalThis } = {}) {
  if (!isSupported(scope)) {
    return { processLocally: true, availability: 'unsupported', reason: 'no-api' };
  }

  const local = await availability(lang, scope);
  if (local === 'available') {
    return { processLocally: true, availability: local, reason: 'local' };
  }

  // Próbujemy raz — na maszynach, gdzie SODA da się doinstalować, to zadziała.
  if (local === 'downloadable' || local === 'downloading') {
    const installed = await install(lang, scope);
    if (installed && (await availability(lang, scope)) === 'available') {
      return { processLocally: true, availability: 'available', reason: 'local' };
    }
  }

  if (allowCloud) {
    return { processLocally: false, availability: local, reason: 'cloud' };
  }
  return { processLocally: true, availability: local, reason: 'model-missing' };
}

/**
 * Pilnuje, kiedy lokalny model stanie się dostępny (np. gdy użytkownik włączy
 * Napisy na żywo w trakcie rozmowy) i woła `onReady`. Bez tego transkrypcja
 * nie ruszyłaby sama nawet po naprawieniu przyczyny.
 */
export class ModelWatcher {
  #timer = null;

  constructor({ lang, intervalMs = 15_000, onReady, scope = globalThis }) {
    this.lang = lang;
    this.intervalMs = intervalMs;
    this.onReady = onReady;
    this.scope = scope;
  }

  start() {
    if (this.#timer) return this;
    this.#timer = setInterval(async () => {
      if ((await availability(this.lang, this.scope)) === 'available') {
        this.stop();
        this.onReady();
      }
    }, this.intervalMs);
    return this;
  }

  stop() {
    clearInterval(this.#timer);
    this.#timer = null;
    return this;
  }
}

export class Recognizer {
  #recognition = null;
  #wanted = false;
  #restartTimer = null;
  #restartDelayMs = 250;

  /**
   * @param {object} options
   * @param {string} options.lang tag BCP-47, np. 'pl-PL'
   * @param {(result: {epoch: number, index: number, transcript: string, isFinal: boolean, at: number}) => void} options.onResult
   */
  constructor({
    lang = 'pl-PL',
    processLocally = true,
    onResult = () => {},
    onError = () => {},
    onStateChange = () => {},
    now = () => Date.now(),
    scope = globalThis,
  } = {}) {
    this.lang = lang;
    this.processLocally = processLocally;
    this.onResult = onResult;
    this.onError = onError;
    this.onStateChange = onStateChange;
    this.now = now;
    this.scope = scope;
    this.epoch = 0;
    this.running = false;
    /** Ostatni błąd niebędący zwykłym końcem wypowiedzi. */
    this.lastError = null;
  }

  /**
   * @param {MediaStreamTrack} [track] źródło audio; bez niego leci mikrofon
   */
  start(track = null) {
    this.track = track ?? this.track ?? null;
    this.#wanted = true;
    this.#spawn();
    return this;
  }

  stop() {
    this.#wanted = false;
    clearTimeout(this.#restartTimer);
    this.#restartTimer = null;
    this.#teardown();
    this.running = false;
    this.onStateChange({ running: false });
    return this;
  }

  #teardown() {
    const recognition = this.#recognition;
    if (!recognition) return;
    this.#recognition = null;
    recognition.onresult = null;
    recognition.onerror = null;
    recognition.onend = null;
    try {
      recognition.abort?.();
    } catch {
      /* już zatrzymane */
    }
  }

  #spawn() {
    const Ctor = speechRecognitionCtor(this.scope);
    if (!Ctor) {
      this.onError(new Error('SpeechRecognition niedostępne w tej przeglądarce'));
      return;
    }
    this.#teardown();

    const recognition = new Ctor();
    recognition.lang = this.lang;
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.maxAlternatives = 1;
    // Nowe API przyjmuje obiekt options; starsze buildy tylko property.
    recognition.processLocally = this.processLocally;
    if ('options' in recognition) {
      recognition.options = { langs: [this.lang], processLocally: this.processLocally };
    }

    this.epoch++;
    const epoch = this.epoch;

    recognition.onresult = (event) => {
      const at = this.now();
      for (let i = event.resultIndex; i < event.results.length; i++) {
        const result = event.results[i];
        const alternative = result?.[0];
        if (!alternative) continue;
        this.onResult({
          epoch,
          index: i,
          transcript: alternative.transcript ?? '',
          confidence: alternative.confidence ?? null,
          isFinal: Boolean(result.isFinal),
          at,
        });
      }
    };

    recognition.onerror = (event) => {
      const code = event?.error ?? 'unknown';
      if (BENIGN_ERRORS.has(code)) return;
      this.lastError = code;
      this.onError(new Error(`SpeechRecognition: ${code}`));
      // 'not-allowed' / 'service-not-allowed' nie naprawi się przez restart.
      // Tych restart nie naprawi — trzeba zmienić konfigurację, nie próbować dalej.
      if (FATAL_ERRORS.has(code)) this.#wanted = false;
    };

    recognition.onend = () => {
      this.running = false;
      this.onStateChange({ running: false });
      if (this.#wanted) this.#scheduleRestart();
    };

    try {
      if (this.track) recognition.start(this.track);
      else recognition.start();
      this.#recognition = recognition;
      this.running = true;
      this.onStateChange({ running: true });
    } catch (error) {
      this.onError(error);
      if (this.#wanted) this.#scheduleRestart();
    }
  }

  #scheduleRestart() {
    clearTimeout(this.#restartTimer);
    this.#restartTimer = setTimeout(() => {
      this.#restartTimer = null;
      if (this.#wanted) this.#spawn();
    }, this.#restartDelayMs);
  }
}
