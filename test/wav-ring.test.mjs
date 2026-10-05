import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encodeWav, durationMs } from '../extension/src/adapters/audio/wav.js';
import { AudioRing } from '../extension/src/adapters/audio/ring.js';

const SR = 16_000;
const ascii = (view, offset, length) =>
  String.fromCharCode(...Array.from({ length }, (_, i) => view.getUint8(offset + i)));

test('encodeWav produkuje poprawny nagłówek RIFF/WAVE', () => {
  const samples = new Float32Array(100);
  const view = new DataView(encodeWav(samples, { sampleRate: SR }));

  assert.equal(ascii(view, 0, 4), 'RIFF');
  assert.equal(ascii(view, 8, 4), 'WAVE');
  assert.equal(ascii(view, 12, 4), 'fmt ');
  assert.equal(ascii(view, 36, 4), 'data');
  assert.equal(view.getUint16(20, true), 1, 'PCM bez kompresji');
  assert.equal(view.getUint16(22, true), 1, 'mono');
  assert.equal(view.getUint32(24, true), SR);
  assert.equal(view.getUint32(28, true), SR * 2, 'bajtów na sekundę');
  assert.equal(view.getUint16(34, true), 16, 'głębia bitowa');
  assert.equal(view.getUint32(40, true), 200, 'bajtów danych');
  assert.equal(view.byteLength, 44 + 200);
});

test('encodeWav mapuje amplitudy i obcina zakres', () => {
  const samples = Float32Array.from([0, 1, -1, 0.5, 2, -3]);
  const view = new DataView(encodeWav(samples));

  assert.equal(view.getInt16(44, true), 0);
  assert.equal(view.getInt16(46, true), 32767, 'pełna skala dodatnia');
  assert.equal(view.getInt16(48, true), -32768, 'pełna skala ujemna');
  assert.equal(view.getInt16(50, true), 16383);
  assert.equal(view.getInt16(52, true), 32767, 'przester obcięty');
  assert.equal(view.getInt16(54, true), -32768);
});

test('durationMs liczy czas z liczby próbek', () => {
  assert.equal(durationMs(16_000, SR), 1000);
  assert.equal(durationMs(8_000, SR), 500);
});

test('AudioRing czyta po czasie', () => {
  const ring = new AudioRing({ sampleRate: SR, seconds: 10, epochMs: 1_000_000 });
  ring.write(Float32Array.from({ length: SR }, (_, i) => i / SR)); // 1 s rampy

  const slice = ring.readRange(1_000_250, 1_000_750);
  assert.equal(slice.length, SR / 2);
  assert.ok(Math.abs(slice[0] - 0.25) < 1e-6);
  assert.ok(Math.abs(slice.at(-1) - (0.75 - 1 / SR)) < 1e-6);
});

test('AudioRing przycina zakres do tego, co jeszcze pamięta', () => {
  const ring = new AudioRing({ sampleRate: SR, seconds: 1, epochMs: 0 });
  ring.write(new Float32Array(SR * 3)); // trzykrotnie przepełniony

  assert.ok(ring.oldestMs >= 2000, `najstarsze ${ring.oldestMs}`);
  assert.equal(ring.readRange(0, 500), null, 'wycinek dawno nadpisany');

  const partial = ring.readRange(1500, 2500);
  assert.ok(partial && partial.length > 0, 'część zakresu wciąż dostępna');
  assert.ok(partial.length < SR, 'i tylko ta część');
});

test('AudioRing zawija się bez gubienia próbek', () => {
  const ring = new AudioRing({ sampleRate: 10, seconds: 1, epochMs: 0 });
  ring.write(Float32Array.from([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]));
  ring.write(Float32Array.from([11, 12, 13]));

  assert.equal(ring.writtenSamples, 13);
  const tail = ring.readRange(1000, 1300);
  assert.deepEqual(Array.from(tail), [11, 12, 13]);
});

test('AudioRing odrzuca puste i odwrócone zakresy', () => {
  const ring = new AudioRing({ sampleRate: SR, seconds: 5 });
  ring.write(new Float32Array(SR));
  assert.equal(ring.readRange(500, 500), null);
  assert.equal(ring.readRange(800, 200), null);
});
