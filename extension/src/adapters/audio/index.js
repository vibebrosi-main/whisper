/**
 * Adapter audio — transkrypcja z realnego dźwięku, niezależna od platformy.
 *
 * Spina dwa niezależne strumienie informacji:
 *   ASR (on-device Web Speech) mówi CO padło,
 *   diaryzator (MFCC + klastrowanie) mówi KTO to powiedział.
 *
 * Wiązanie jest czasowe: dla każdego wyniku ASR pytamy diaryzator, kto
 * dominował w oknie czasu tego wyniku. To przybliżenie — Web Speech nie oddaje
 * znaczników czasu słów — ale przy naprzemiennej rozmowie działa dobrze.
 *
 * WAŻNE: `pushFrame(frame, tMs)` i zegar wstrzyknięty do Recognizera muszą
 * chodzić w tej samej skali czasu (domyślnie epoka Date.now()).
 */

import { Diarizer } from './diarizer.js';
import { Recognizer } from './asr.js';

export const SOURCE_LABELS = {
  /** Zdalni uczestnicy — audio karty. */
  tab: (index) => `Rozmówca ${index + 1}`,
  /** Lokalny mikrofon: pierwszy głos to użytkownik, kolejne to osoby obok. */
  mic: (index) => (index === 0 ? 'Ty' : `Osoba obok ${index}`),
};

const DEFAULTS = {
  /**
   * O ile cofamy okno wyniku ASR, gdy nie mamy poprzedniego punktu odniesienia.
   * Rozpoznawanie oddaje tekst z opóźnieniem względem mowy.
   */
  preRollMs: 1500,
  /** Etykieta, gdy diaryzator nie zdążył jeszcze nikogo rozpoznać. */
  fallbackLabel: 'Nieznany',
};

export class AudioAdapter {
  static id = 'audio';

  /** index wyniku ASR -> okno czasu i przypisany mówca */
  #windows = new Map();
  #lastFinalAt = null;

  /**
   * @param {object} options
   * @param {import('../../core/transcript.js').TranscriptStore} options.store
   * @param {'tab'|'mic'} [options.source]
   */
  constructor({
    store,
    source = 'tab',
    lang = 'pl-PL',
    processLocally = true,
    label,
    diarizer,
    recognizer,
    onChange = () => {},
    onError = () => {},
    now = () => Date.now(),
    ...options
  } = {}) {
    if (!store) throw new Error('AudioAdapter wymaga store');
    const config = { ...DEFAULTS, ...options };

    this.store = store;
    this.source = source;
    this.now = now;
    this.preRollMs = config.preRollMs;
    this.fallbackLabel = config.fallbackLabel;
    this.label = label ?? SOURCE_LABELS[source] ?? SOURCE_LABELS.tab;
    this.onChange = onChange;

    this.diarizer = diarizer ?? new Diarizer(options);
    this.recognizer =
      recognizer ??
      new Recognizer({
        lang,
        processLocally,
        now,
        onResult: (result) => this.handleResult(result),
        onError,
        ...options,
      });
    // Także wstrzyknięty recognizer (testy, inny backend ASR) ma raportować tutaj.
    this.recognizer.onResult = (result) => this.handleResult(result);

    this.running = false;
  }

  /** Ramka PCM ze źródła audio (długość = frameSize ekstraktora). */
  pushFrame(frame, tMs) {
    if (!this.running) return null;
    return this.diarizer.pushFrame(frame, tMs);
  }

  /** Wynik z ASR — pełna migawka tekstu dla danego indeksu. */
  handleResult({ epoch, index, transcript, isFinal, at }) {
    if (!this.running) return null;
    const text = String(transcript ?? '').trim();
    if (!text) return null;

    const key = `asr:${this.source}:${epoch}:${index}`;
    let window = this.#windows.get(key);
    if (!window) {
      window = { startMs: this.#lastFinalAt ?? at - this.preRollMs, endMs: at, speaker: null };
      this.#windows.set(key, window);
    }
    window.endMs = at;

    // Mówcę ustalamy raz i już nim nie chwiejemy — przeskakiwanie etykiety
    // w trakcie wypowiedzi rozbijałoby segment na kawałki.
    if (window.speaker === null) {
      const speakerIndex = this.diarizer.dominantSpeaker(window.startMs, window.endMs);
      if (speakerIndex !== null) window.speaker = this.label(speakerIndex);
    }

    const segment = this.store.upsert({
      key,
      speaker: window.speaker ?? this.fallbackLabel,
      text,
      at,
      // Web Speech podaje pełną hipotezę przy każdej aktualizacji, nie ogon.
      replace: true,
    });

    if (isFinal) {
      this.#lastFinalAt = at;
      this.store.seal(key, at);
      this.#windows.delete(key);
    }

    this.onChange(this.store);
    return segment;
  }

  start(track = null) {
    if (this.running) return this;
    this.running = true;
    this.recognizer.start(track);
    return this;
  }

  stop() {
    if (!this.running) return this;
    this.running = false;
    this.recognizer.stop();
    this.diarizer.flush(this.now());
    for (const key of this.#windows.keys()) this.store.dropKey(key, this.now());
    this.#windows.clear();
    this.store.finalizeAll(this.now());
    this.onChange(this.store);
    return this;
  }

  get status() {
    return {
      running: this.running,
      source: this.source,
      speakers: this.diarizer.speakerCount,
      recognizing: this.recognizer.running,
      error: this.recognizer.lastError,
    };
  }
}
