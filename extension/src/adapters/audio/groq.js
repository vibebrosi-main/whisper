/**
 * Klient Speech-to-Text Groqa (Whisper large-v3).
 *
 * Groq nie ma streamingu — to zwykły POST pliku. Dlatego audio tniemy na
 * granicach wypowiedzi wykrytych przez VAD: każde żądanie to jedna tura
 * jednego mówcy. Efekt uboczny jest cenniejszy niż sama dokładność —
 * przypisanie osoby przestaje być zgadywaniem, bo chunk *z definicji* należy
 * do jednego mówcy.
 *
 * Uwaga na koszty: Groq nalicza minimum 10 s na żądanie niezależnie od
 * długości, więc bardzo krótkie wtrącenia odsiewamy przed wysyłką.
 */

export const GROQ_ENDPOINT = 'https://api.groq.com/openai/v1/audio/transcriptions';

export const GROQ_MODELS = [
  { id: 'whisper-large-v3-turbo', label: 'large-v3-turbo (szybszy, tańszy)', wer: 12, pricePerHour: 0.04 },
  { id: 'whisper-large-v3', label: 'large-v3 (dokładniejszy)', wer: 10.3, pricePerHour: 0.111 },
];

export const DEFAULT_MODEL = 'whisper-large-v3-turbo';

/** Limit darmowego planu; nad nim Groq odrzuca żądanie. */
export const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;

/** Statusy, po których warto spróbować ponownie. */
const RETRIABLE = new Set([408, 429, 500, 502, 503, 504]);

export class GroqError extends Error {
  constructor(message, { status = null, retriable = false, code = null } = {}) {
    super(message);
    this.name = 'GroqError';
    this.status = status;
    this.retriable = retriable;
    this.code = code;
  }
}

function describeFailure(status, body) {
  const detail = body?.error?.message ?? '';
  switch (status) {
    case 401:
      return new GroqError('Nieprawidłowy klucz API Groq', { status, code: 'bad-key' });
    case 403:
      return new GroqError('Klucz API nie ma dostępu do transkrypcji', { status, code: 'forbidden' });
    case 413:
      return new GroqError('Nagranie za duże dla planu Groq', { status, code: 'too-large' });
    case 429:
      return new GroqError('Limit Groq wyczerpany — zwalniam', { status, retriable: true, code: 'rate-limit' });
    default:
      return new GroqError(detail || `Groq zwrócił ${status}`, {
        status,
        retriable: RETRIABLE.has(status),
        code: 'http',
      });
  }
}

export class GroqTranscriber {
  /**
   * @param {object} options
   * @param {string} options.apiKey
   * @param {string} [options.model]
   * @param {string} [options.language] kod ISO-639-1, np. 'pl' — podany skraca czas i poprawia wynik
   */
  constructor({
    apiKey,
    model = DEFAULT_MODEL,
    language = null,
    endpoint = GROQ_ENDPOINT,
    fetchImpl = globalThis.fetch?.bind(globalThis),
    maxRetries = 3,
    baseDelayMs = 700,
    sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  } = {}) {
    if (!apiKey) throw new Error('GroqTranscriber wymaga klucza API');
    this.apiKey = apiKey;
    this.model = model;
    this.language = language;
    this.endpoint = endpoint;
    this.fetchImpl = fetchImpl;
    this.maxRetries = maxRetries;
    this.baseDelayMs = baseDelayMs;
    this.sleep = sleep;
  }

  /**
   * @param {ArrayBuffer} wav
   * @returns {Promise<{text: string, segments: Array<{start: number, end: number, text: string}>}>}
   */
  async transcribe(wav, { signal } = {}) {
    if (wav.byteLength > MAX_UPLOAD_BYTES) {
      throw new GroqError('Nagranie przekracza 25 MB', { code: 'too-large' });
    }

    const form = new FormData();
    form.append('file', new Blob([wav], { type: 'audio/wav' }), 'utterance.wav');
    form.append('model', this.model);
    form.append('response_format', 'verbose_json');
    form.append('temperature', '0');
    if (this.language) form.append('language', this.language);

    let lastError = null;
    for (let attempt = 0; attempt <= this.maxRetries; attempt++) {
      if (attempt > 0) await this.sleep(this.baseDelayMs * 2 ** (attempt - 1));

      let response;
      try {
        response = await this.fetchImpl(this.endpoint, {
          method: 'POST',
          headers: { Authorization: `Bearer ${this.apiKey}` },
          body: form,
          signal,
        });
      } catch (error) {
        // Sieć padła — to zawsze warto powtórzyć.
        lastError = new GroqError(`Błąd sieci: ${error?.message ?? error}`, { retriable: true, code: 'network' });
        continue;
      }

      if (response.ok) return parseResponse(await response.json());

      let body = null;
      try {
        body = await response.json();
      } catch {
        /* odpowiedź bez JSON-a */
      }
      const failure = describeFailure(response.status, body);
      if (!failure.retriable) throw failure;
      lastError = failure;
    }
    throw lastError ?? new GroqError('Transkrypcja nie powiodła się');
  }
}

function parseResponse(payload) {
  const segments = Array.isArray(payload?.segments)
    ? payload.segments
        .map((s) => ({ start: Number(s.start) || 0, end: Number(s.end) || 0, text: String(s.text ?? '').trim() }))
        .filter((s) => s.text)
    : [];
  const text = String(payload?.text ?? segments.map((s) => s.text).join(' ')).trim();
  return { text, segments };
}

/**
 * Szeregowa kolejka żądań.
 *
 * Wypowiedzi wpadają szybciej, niż lecą odpowiedzi, a kolejność w transkrypcie
 * musi się zgadzać — dlatego jedno żądanie naraz i zachowana kolejność wejścia.
 */
export class TranscriptionQueue {
  #chain = Promise.resolve();
  #pending = 0;

  constructor({ transcriber, onResult, onError = () => {}, maxPending = 12 }) {
    this.transcriber = transcriber;
    this.onResult = onResult;
    this.onError = onError;
    this.maxPending = maxPending;
    this.dropped = 0;
  }

  get pending() {
    return this.#pending;
  }

  /**
   * @param {{wav: ArrayBuffer, meta: object}} job
   * @returns {boolean} czy przyjęto do kolejki
   */
  enqueue({ wav, meta }) {
    if (this.#pending >= this.maxPending) {
      // Zaległości oznaczają, że i tak nie nadążymy — lepiej zgubić kawałek
      // niż budować kolejkę rosnącą bez końca.
      this.dropped++;
      return false;
    }
    this.#pending++;
    this.#chain = this.#chain.then(async () => {
      try {
        const result = await this.transcriber.transcribe(wav);
        if (result.text) this.onResult(result, meta);
      } catch (error) {
        this.onError(error, meta);
      } finally {
        this.#pending--;
      }
    });
    return true;
  }

  /** Czeka, aż kolejka się opróżni — używane przy zatrzymaniu nagrywania. */
  async drain() {
    await this.#chain;
  }
}
