/**
 * FFT radix-2 (Cooley-Tukey), in-place, bez zależności.
 * Używana przez ekstrakcję cech MFCC do diaryzacji mówców.
 */

/** Czy n jest potęgą dwójki (i > 0). */
export function isPowerOfTwo(n) {
  return Number.isInteger(n) && n > 0 && (n & (n - 1)) === 0;
}

/** Najbliższa potęga dwójki >= n. */
export function nextPowerOfTwo(n) {
  let size = 1;
  while (size < n) size <<= 1;
  return size;
}

const tableCache = new Map();

/** Tablice sin/cos i permutacji bitowej dla danego rozmiaru — liczone raz. */
function tablesFor(n) {
  let tables = tableCache.get(n);
  if (tables) return tables;

  const levels = Math.log2(n);
  const cos = new Float64Array(n / 2);
  const sin = new Float64Array(n / 2);
  for (let i = 0; i < n / 2; i++) {
    cos[i] = Math.cos((2 * Math.PI * i) / n);
    sin[i] = Math.sin((2 * Math.PI * i) / n);
  }

  const reverse = new Uint32Array(n);
  for (let i = 0; i < n; i++) {
    let x = i;
    let r = 0;
    for (let j = 0; j < levels; j++) {
      r = (r << 1) | (x & 1);
      x >>= 1;
    }
    reverse[i] = r;
  }

  tables = { cos, sin, reverse };
  tableCache.set(n, tables);
  return tables;
}

/**
 * FFT w miejscu na tablicach części rzeczywistej i urojonej.
 * @param {Float64Array|Float32Array} re
 * @param {Float64Array|Float32Array} im
 */
export function fft(re, im) {
  const n = re.length;
  if (n !== im.length) throw new Error('fft: re i im muszą mieć tę samą długość');
  if (!isPowerOfTwo(n)) throw new Error(`fft: długość musi być potęgą dwójki, dostałem ${n}`);
  if (n === 1) return;

  const { cos, sin, reverse } = tablesFor(n);

  // Permutacja bitowo-odwrotna.
  for (let i = 0; i < n; i++) {
    const j = reverse[i];
    if (j > i) {
      let tmp = re[i];
      re[i] = re[j];
      re[j] = tmp;
      tmp = im[i];
      im[i] = im[j];
      im[j] = tmp;
    }
  }

  for (let size = 2; size <= n; size *= 2) {
    const half = size / 2;
    const step = n / size;
    for (let i = 0; i < n; i += size) {
      for (let j = i, k = 0; j < i + half; j++, k += step) {
        const l = j + half;
        const tre = re[l] * cos[k] + im[l] * sin[k];
        const tim = -re[l] * sin[k] + im[l] * cos[k];
        re[l] = re[j] - tre;
        im[l] = im[j] - tim;
        re[j] += tre;
        im[j] += tim;
      }
    }
  }
}

/**
 * Widmo mocy sygnału rzeczywistego: |X(k)|^2 dla k = 0..n/2.
 * @param {Float32Array|Float64Array} frame ramka o długości będącej potęgą dwójki
 * @returns {Float64Array} n/2 + 1 prążków
 */
export function powerSpectrum(frame) {
  const n = frame.length;
  const re = Float64Array.from(frame);
  const im = new Float64Array(n);
  fft(re, im);

  const bins = new Float64Array(n / 2 + 1);
  for (let i = 0; i < bins.length; i++) {
    bins[i] = re[i] * re[i] + im[i] * im[i];
  }
  return bins;
}
