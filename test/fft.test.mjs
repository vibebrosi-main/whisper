import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fft, powerSpectrum, isPowerOfTwo, nextPowerOfTwo } from '../extension/src/adapters/audio/fft.js';

/** Naiwna DFT — wzorzec odniesienia dla FFT. */
function dft(input) {
  const n = input.length;
  const re = new Float64Array(n);
  const im = new Float64Array(n);
  for (let k = 0; k < n; k++) {
    for (let t = 0; t < n; t++) {
      const angle = (-2 * Math.PI * k * t) / n;
      re[k] += input[t] * Math.cos(angle);
      im[k] += input[t] * Math.sin(angle);
    }
  }
  return { re, im };
}

test('isPowerOfTwo / nextPowerOfTwo', () => {
  assert.equal(isPowerOfTwo(512), true);
  assert.equal(isPowerOfTwo(400), false);
  assert.equal(isPowerOfTwo(0), false);
  assert.equal(nextPowerOfTwo(400), 512);
  assert.equal(nextPowerOfTwo(512), 512);
});

test('fft zgadza się z naiwną DFT co do 1e-9', () => {
  const n = 256;
  const signal = Float64Array.from({ length: n }, (_, i) => Math.sin(i / 3) + 0.4 * Math.cos(i / 7) + (i % 5) * 0.01);
  const expected = dft(signal);

  const re = Float64Array.from(signal);
  const im = new Float64Array(n);
  fft(re, im);

  for (let k = 0; k < n; k++) {
    assert.ok(Math.abs(re[k] - expected.re[k]) < 1e-9, `re[${k}] ${re[k]} != ${expected.re[k]}`);
    assert.ok(Math.abs(im[k] - expected.im[k]) < 1e-9, `im[${k}] ${im[k]} != ${expected.im[k]}`);
  }
});

test('fft odrzuca długości spoza potęg dwójki', () => {
  assert.throws(() => fft(new Float64Array(300), new Float64Array(300)), /potęgą dwójki/);
});

test('powerSpectrum lokalizuje czysty ton we właściwym prążku', () => {
  const n = 512;
  const sampleRate = 16_000;
  const freq = 1000;
  const bin = Math.round((freq * n) / sampleRate); // 32
  const frame = Float64Array.from({ length: n }, (_, i) => Math.sin((2 * Math.PI * freq * i) / sampleRate));

  const spectrum = powerSpectrum(frame);
  assert.equal(spectrum.length, n / 2 + 1);

  let peak = 0;
  for (let i = 1; i < spectrum.length; i++) if (spectrum[i] > spectrum[peak]) peak = i;
  assert.equal(peak, bin);

  // Energia skupiona w piku, nie rozmazana po widmie.
  const total = spectrum.reduce((a, b) => a + b, 0);
  assert.ok(spectrum[peak] / total > 0.4, `pik trzyma ${(spectrum[peak] / total).toFixed(2)} energii`);
});

test('powerSpectrum ciszy to same zera', () => {
  const spectrum = powerSpectrum(new Float64Array(128));
  assert.ok(spectrum.every((v) => v === 0));
});
