/**
 * Ekstrakcja cech MFCC — reprezentacja barwy głosu, na której opiera się
 * rozpoznawanie mówcy. Klasyczny łańcuch: preemfaza -> okno Hamminga -> FFT ->
 * bank filtrów mel -> log -> DCT-II.
 *
 * Wszystko to czyste funkcje na Float32Array/Float64Array — testowalne w node
 * bez Web Audio.
 */

import { powerSpectrum, nextPowerOfTwo } from './fft.js';

export const DEFAULTS = {
  sampleRate: 16_000,
  frameMs: 25,
  hopMs: 10,
  melFilters: 26,
  /** Ile współczynników cepstralnych zatrzymujemy (bez c0). */
  cepstra: 12,
  fMin: 80,
  fMax: 7600,
  preemphasis: 0.97,
};

export const hzToMel = (hz) => 2595 * Math.log10(1 + hz / 700);
export const melToHz = (mel) => 700 * (10 ** (mel / 2595) - 1);

/** Okno Hamminga długości n. */
export function hammingWindow(n) {
  const w = new Float64Array(n);
  for (let i = 0; i < n; i++) w[i] = 0.54 - 0.46 * Math.cos((2 * Math.PI * i) / (n - 1));
  return w;
}

/**
 * Filtr preemfazy y[n] = x[n] - a*x[n-1].
 * Podbija wysokie częstotliwości, gdzie siedzi informacja o formantach.
 */
export function preemphasize(frame, coeff = DEFAULTS.preemphasis, previous = 0) {
  const out = new Float64Array(frame.length);
  out[0] = frame[0] - coeff * previous;
  for (let i = 1; i < frame.length; i++) out[i] = frame[i] - coeff * frame[i - 1];
  return out;
}

/**
 * Trójkątny bank filtrów w skali mel.
 * @returns {Array<{start: number, weights: Float64Array}>} filtry rzadkie
 */
export function melFilterbank({
  sampleRate = DEFAULTS.sampleRate,
  fftSize = 512,
  filters = DEFAULTS.melFilters,
  fMin = DEFAULTS.fMin,
  fMax = DEFAULTS.fMax,
} = {}) {
  const nyquist = sampleRate / 2;
  const top = Math.min(fMax, nyquist);
  const melMin = hzToMel(fMin);
  const melMax = hzToMel(top);
  const bins = fftSize / 2 + 1;

  // filters + 2 punktów: każdy filtr ma lewy, środkowy i prawy wierzchołek.
  const points = new Float64Array(filters + 2);
  for (let i = 0; i < points.length; i++) {
    const mel = melMin + ((melMax - melMin) * i) / (filters + 1);
    points[i] = Math.floor(((fftSize + 1) * melToHz(mel)) / sampleRate);
  }

  const bank = [];
  for (let m = 1; m <= filters; m++) {
    const left = points[m - 1];
    const center = points[m];
    const right = points[m + 1];
    const start = Math.max(0, left);
    const end = Math.min(bins - 1, right);
    const weights = new Float64Array(Math.max(0, end - start + 1));

    for (let k = start; k <= end; k++) {
      let value = 0;
      if (k >= left && k <= center && center > left) value = (k - left) / (center - left);
      else if (k > center && k <= right && right > center) value = (right - k) / (right - center);
      weights[k - start] = value;
    }
    bank.push({ start, weights });
  }
  return bank;
}

/** Energie logarytmiczne w pasmach mel. */
export function logMelEnergies(spectrum, bank, floor = 1e-10) {
  const out = new Float64Array(bank.length);
  for (let m = 0; m < bank.length; m++) {
    const { start, weights } = bank[m];
    let sum = 0;
    for (let i = 0; i < weights.length; i++) {
      const bin = start + i;
      if (bin < spectrum.length) sum += spectrum[bin] * weights[i];
    }
    out[m] = Math.log(Math.max(sum, floor));
  }
  return out;
}

/** DCT-II (ortonormalna) — pierwsze `count` współczynników. */
export function dct2(input, count) {
  const n = input.length;
  const out = new Float64Array(count);
  const scale0 = Math.sqrt(1 / n);
  const scale = Math.sqrt(2 / n);
  for (let k = 0; k < count; k++) {
    let sum = 0;
    for (let i = 0; i < n; i++) sum += input[i] * Math.cos((Math.PI * k * (2 * i + 1)) / (2 * n));
    out[k] = sum * (k === 0 ? scale0 : scale);
  }
  return out;
}

/**
 * Gotowy ekstraktor — trzyma okno, bank filtrów i rozmiar FFT.
 * Jedna instancja na źródło audio.
 */
export class MfccExtractor {
  constructor(options = {}) {
    const config = { ...DEFAULTS, ...options };
    this.sampleRate = config.sampleRate;
    this.frameSize = Math.round((config.frameMs / 1000) * config.sampleRate);
    this.hopSize = Math.round((config.hopMs / 1000) * config.sampleRate);
    this.fftSize = nextPowerOfTwo(this.frameSize);
    this.cepstra = config.cepstra;
    this.preemphasisCoeff = config.preemphasis;
    this.window = hammingWindow(this.frameSize);
    this.bank = melFilterbank({
      sampleRate: config.sampleRate,
      fftSize: this.fftSize,
      filters: config.melFilters,
      fMin: config.fMin,
      fMax: config.fMax,
    });
  }

  /**
   * MFCC pojedynczej ramki (bez c0 — c0 to głośność, nie barwa głosu).
   * @param {Float32Array|Float64Array} frame długości frameSize
   * @returns {Float64Array} cepstra współczynników
   */
  frameToMfcc(frame) {
    const emphasized = preemphasize(frame, this.preemphasisCoeff);
    const padded = new Float64Array(this.fftSize);
    for (let i = 0; i < this.frameSize; i++) padded[i] = emphasized[i] * this.window[i];

    const spectrum = powerSpectrum(padded);
    const melEnergies = logMelEnergies(spectrum, this.bank);
    const cepstrum = dct2(melEnergies, this.cepstra + 1);
    return cepstrum.slice(1); // odrzucamy c0
  }

  /** Energia ramki w dB — używana przez VAD. */
  static frameEnergyDb(frame) {
    let sum = 0;
    for (let i = 0; i < frame.length; i++) sum += frame[i] * frame[i];
    return 10 * Math.log10(Math.max(sum / frame.length, 1e-12));
  }
}
