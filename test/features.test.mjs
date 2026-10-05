import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  hzToMel,
  melToHz,
  hammingWindow,
  preemphasize,
  melFilterbank,
  dct2,
  MfccExtractor,
} from '../extension/src/adapters/audio/features.js';

const SR = 16_000;

/** Syntetyczna samogłoska: ton krtaniowy + formanty. */
function vowel({ f0, formants, length = 400, sampleRate = SR, seed = 1 }) {
  let rng = seed;
  const random = () => {
    rng = (rng * 1103515245 + 12345) % 2147483648;
    return rng / 2147483648 - 0.5;
  };
  const out = new Float64Array(length);
  for (let i = 0; i < length; i++) {
    const t = i / sampleRate;
    let value = 0.5 * Math.sin(2 * Math.PI * f0 * t);
    for (const [freq, gain] of formants) value += gain * Math.sin(2 * Math.PI * freq * t);
    out[i] = value + 0.01 * random();
  }
  return out;
}

test('konwersja hz <-> mel jest odwracalna', () => {
  for (const hz of [0, 100, 700, 1000, 4000, 8000]) {
    assert.ok(Math.abs(melToHz(hzToMel(hz)) - hz) < 1e-6);
  }
  assert.ok(hzToMel(1000) > hzToMel(500));
});

test('okno Hamminga ma poprawny kształt', () => {
  const w = hammingWindow(64);
  assert.ok(Math.abs(w[0] - 0.08) < 1e-9);
  assert.ok(Math.abs(w[63] - 0.08) < 1e-9);
  assert.ok(Math.abs(w[32] - 1) < 0.01);
  assert.ok(Math.abs(w[10] - w[53]) < 1e-9, 'symetria');
});

test('preemfaza tłumi składową stałą', () => {
  const flat = new Float64Array(32).fill(1);
  const out = preemphasize(flat, 0.97);
  assert.ok(Math.abs(out[0] - 1) < 1e-9);
  for (let i = 1; i < out.length; i++) assert.ok(Math.abs(out[i] - 0.03) < 1e-9);
});

test('bank filtrów mel pokrywa pasmo bez dziur', () => {
  const bank = melFilterbank({ sampleRate: SR, fftSize: 512, filters: 26 });
  assert.equal(bank.length, 26);
  for (const filter of bank) {
    assert.ok(filter.weights.length > 0);
    assert.ok(Math.max(...filter.weights) > 0.5, 'każdy filtr ma wierzchołek');
  }
  // Filtry rosną wzdłuż osi częstotliwości.
  for (let i = 1; i < bank.length; i++) assert.ok(bank[i].start >= bank[i - 1].start);
});

test('dct2 jest ortonormalna — stała daje energię tylko w c0', () => {
  const constant = new Float64Array(26).fill(3);
  const out = dct2(constant, 5);
  assert.ok(Math.abs(out[0] - 3 * Math.sqrt(26)) < 1e-9);
  for (let k = 1; k < 5; k++) assert.ok(Math.abs(out[k]) < 1e-9, `c${k} powinno być zerem`);
});

test('MFCC jest deterministyczne i ma właściwy rozmiar', () => {
  const extractor = new MfccExtractor({ sampleRate: SR });
  assert.equal(extractor.frameSize, 400);
  assert.equal(extractor.fftSize, 512);

  const frame = vowel({ f0: 120, formants: [[700, 0.3], [1200, 0.2]] });
  const a = extractor.frameToMfcc(frame);
  const b = extractor.frameToMfcc(frame);
  assert.equal(a.length, 12);
  assert.deepEqual(Array.from(a), Array.from(b));
  assert.ok(a.every(Number.isFinite));
});

test('MFCC nie reaguje na samą głośność, reaguje na barwę', () => {
  const extractor = new MfccExtractor({ sampleRate: SR });
  const base = vowel({ f0: 120, formants: [[700, 0.3], [1200, 0.2]] });
  const louder = Float64Array.from(base, (v) => v * 4);
  const different = vowel({ f0: 210, formants: [[400, 0.3], [2400, 0.25]] });

  const distance = (x, y) => Math.hypot(...x.map((v, i) => v - y[i]));

  const quiet = extractor.frameToMfcc(base);
  const loud = extractor.frameToMfcc(louder);
  const other = extractor.frameToMfcc(different);

  // Wzmocnienie sygnału przesuwa głównie c0, które odrzuciliśmy.
  assert.ok(distance(quiet, loud) < distance(quiet, other) / 2,
    `głośność ${distance(quiet, loud).toFixed(2)} vs barwa ${distance(quiet, other).toFixed(2)}`);
});

test('energia ramki w dB rośnie z amplitudą', () => {
  const quiet = new Float64Array(400).fill(0.01);
  const loud = new Float64Array(400).fill(0.5);
  const silence = new Float64Array(400);
  assert.ok(MfccExtractor.frameEnergyDb(loud) > MfccExtractor.frameEnergyDb(quiet));
  assert.ok(MfccExtractor.frameEnergyDb(silence) < -100);
});
