/**
 * Cięcie ciągłego strumienia próbek na nachodzące ramki analizy.
 *
 * AudioWorklet oddaje paczki próbek o dowolnej długości, a MFCC potrzebuje
 * ramek stałej długości (25 ms) co stały skok (10 ms). Framer trzyma bufor
 * przejściowy i liczy czas każdej ramki z numeru próbki, a nie z zegara —
 * dzięki temu znaczniki nie dryfują nawet przy zacinającym się audio.
 */

export class Framer {
  #buffer;
  #filled = 0;
  #consumedSamples = 0;

  /**
   * @param {object} options
   * @param {number} options.frameSize liczba próbek w ramce
   * @param {number} options.hopSize skok między ramkami
   * @param {number} options.sampleRate
   * @param {number} [options.epochMs] czas próbki 0 (np. Date.now() startu nagrania)
   * @param {(frame: Float32Array, tMs: number) => void} options.onFrame
   */
  constructor({ frameSize, hopSize, sampleRate, epochMs = 0, onFrame }) {
    if (!(frameSize > 0) || !(hopSize > 0)) throw new Error('Framer: frameSize i hopSize muszą być dodatnie');
    if (hopSize > frameSize) throw new Error('Framer: hopSize nie może być większy od frameSize');
    this.frameSize = frameSize;
    this.hopSize = hopSize;
    this.sampleRate = sampleRate;
    this.epochMs = epochMs;
    this.onFrame = onFrame;
    // Bufor mieści ramkę plus zapas na jedną paczkę wejściową.
    this.#buffer = new Float32Array(frameSize * 4);
  }

  /** @param {Float32Array} samples paczka próbek ze źródła */
  push(samples) {
    let offset = 0;
    while (offset < samples.length) {
      const room = this.#buffer.length - this.#filled;
      const take = Math.min(room, samples.length - offset);
      this.#buffer.set(samples.subarray(offset, offset + take), this.#filled);
      this.#filled += take;
      offset += take;
      this.#drain();
    }
  }

  #drain() {
    while (this.#filled >= this.frameSize) {
      const frame = this.#buffer.slice(0, this.frameSize);
      const tMs = this.epochMs + (this.#consumedSamples / this.sampleRate) * 1000;
      this.onFrame(frame, tMs);

      this.#buffer.copyWithin(0, this.hopSize, this.#filled);
      this.#filled -= this.hopSize;
      this.#consumedSamples += this.hopSize;
    }
  }

  /** Liczba próbek, które opuściły bufor — do diagnostyki. */
  get processedSamples() {
    return this.#consumedSamples;
  }

  reset() {
    this.#filled = 0;
    this.#consumedSamples = 0;
  }
}
