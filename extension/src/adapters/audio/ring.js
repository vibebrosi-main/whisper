/**
 * Kołowy bufor audio.
 *
 * Diaryzator mówi „tura mówcy trwała od 12 340 ms do 17 800 ms" dopiero po jej
 * zakończeniu — więc surowe audio musi gdzieś czekać, żeby dało się je wtedy
 * wyciąć i wysłać do transkrypcji. Bufor trzyma ostatnie N sekund i pozwala
 * czytać po czasie, nie po indeksie.
 */

export class AudioRing {
  #buffer;
  #written = 0;

  /**
   * @param {{sampleRate?: number, seconds?: number, epochMs?: number}} options
   */
  constructor({ sampleRate = 16_000, seconds = 90, epochMs = 0 } = {}) {
    this.sampleRate = sampleRate;
    this.epochMs = epochMs;
    this.capacity = Math.max(1, Math.round(sampleRate * seconds));
    this.#buffer = new Float32Array(this.capacity);
  }

  /** @param {Float32Array} samples */
  write(samples) {
    for (let i = 0; i < samples.length; i++) {
      this.#buffer[(this.#written + i) % this.capacity] = samples[i];
    }
    this.#written += samples.length;
  }

  /** Najstarszy czas, który jeszcze mamy. */
  get oldestMs() {
    const oldestSample = Math.max(0, this.#written - this.capacity);
    return this.epochMs + (oldestSample / this.sampleRate) * 1000;
  }

  get newestMs() {
    return this.epochMs + (this.#written / this.sampleRate) * 1000;
  }

  get writtenSamples() {
    return this.#written;
  }

  /**
   * Wycinek audio dla zakresu czasu. Zakres jest przycinany do tego, co bufor
   * jeszcze pamięta — lepiej oddać krótszą wypowiedź niż nic.
   * @returns {Float32Array|null} null, gdy zakres wypadł całkowicie poza bufor
   */
  readRange(startMs, endMs) {
    if (!(endMs > startMs)) return null;

    const toSample = (ms) => Math.round(((ms - this.epochMs) / 1000) * this.sampleRate);
    const oldest = Math.max(0, this.#written - this.capacity);
    const from = Math.max(oldest, toSample(startMs));
    const to = Math.min(this.#written, toSample(endMs));
    if (to <= from) return null;

    const out = new Float32Array(to - from);
    for (let i = 0; i < out.length; i++) {
      out[i] = this.#buffer[(from + i) % this.capacity];
    }
    return out;
  }

  reset() {
    this.#buffer.fill(0);
    this.#written = 0;
  }
}
