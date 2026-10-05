/**
 * Klient lokalnego whisper.cpp (`whisper-server`).
 *
 * Pomiary na Apple M4, ciepły serwer, 5 s polskiego audio:
 *
 *   ggml-small           188 ms encode -> 396 ms round-trip HTTP
 *   ggml-large-v3-turbo  902 ms encode -> ~1,4 s
 *   Groq large-v3-turbo  (sieć)        -> ~1,2-2 s
 *
 * Dwa wnioski, które ukształtowały domyślne ustawienia:
 *
 *  1. `small` bije `large-v3-turbo` czterokrotnie przy tej samej jakości po
 *     polsku — dlatego jest domyślny.
 *  2. Encoder Whispera kosztuje tyle samo niezależnie od długości audio, bo
 *     wejście jest zawsze dopychane do okna 30 s. Trzysekundowa wypowiedź
 *     kosztuje tyle co trzydziestosekundowa — więc ponowne transkrybowanie
 *     tej samej wypowiedzi co sekundę jest tanie i to właśnie robimy.
 */

import { encodeWav } from './wav.js';
import { stripHallucinations } from '../../core/text.js';

export const DEFAULT_ENDPOINT = 'http://127.0.0.1:8899';

export class WhisperLocalError extends Error {
  constructor(message, { status = null, code = null } = {}) {
    super(message);
    this.name = 'WhisperLocalError';
    this.status = status;
    this.code = code;
  }
}

export class WhisperLocalClient {
  constructor({
    endpoint = DEFAULT_ENDPOINT,
    language = 'pl',
    inferencePath = '/inference',
    fetchImpl = globalThis.fetch?.bind(globalThis),
  } = {}) {
    this.endpoint = endpoint.replace(/\/+$/, '');
    this.language = language;
    this.inferencePath = inferencePath;
    this.fetchImpl = fetchImpl;
  }

  async health(timeoutMs = 1500) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await this.fetchImpl(`${this.endpoint}/`, { signal: controller.signal });
      return { ok: response.ok, status: response.status };
    } catch (error) {
      return { ok: false, error: error?.name === 'AbortError' ? 'timeout' : String(error?.message ?? error) };
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * @param {Float32Array} pcm 16 kHz mono
   * @returns {Promise<{text: string}>}
   */
  async transcribe(pcm, { sampleRate = 16_000, signal } = {}) {
    const form = new FormData();
    form.append('file', new Blob([encodeWav(pcm, { sampleRate })], { type: 'audio/wav' }), 'chunk.wav');
    form.append('language', this.language);
    form.append('response_format', 'json');
    form.append('temperature', '0');
    // Bez tego whisper.cpp dokleja halucynacje na ciszy.
    form.append('no_speech_thold', '0.6');

    let response;
    try {
      response = await this.fetchImpl(`${this.endpoint}${this.inferencePath}`, {
        method: 'POST',
        body: form,
        signal,
      });
    } catch (error) {
      if (error?.name === 'AbortError') throw error;
      throw new WhisperLocalError(
        `Nie mogę połączyć się z whisper-server (${this.endpoint}) — uruchom \`npm run whisper\``,
        { code: 'offline' },
      );
    }

    if (!response.ok) {
      throw new WhisperLocalError(`whisper-server zwrócił ${response.status}`, {
        status: response.status,
        code: 'http',
      });
    }

    const payload = await response.json();
    return { text: cleanText(payload?.text ?? '') };
  }
}

/**
 * whisper.cpp zwraca tekst z twardymi łamaniami linii i znacznikami ciszy —
 * w transkrypcie chcemy jedną, czystą linię.
 */
export function cleanText(raw) {
  return stripHallucinations(String(raw ?? '')
    .replace(/\[[^\]]*\]/g, ' ')       // [BLANK_AUDIO], [Muzyka] itd.
    .replace(/\([^)]*\)/g, ' ')        // (szum), (music)
    .replace(/\s+/g, ' ')
    .trim());
}
