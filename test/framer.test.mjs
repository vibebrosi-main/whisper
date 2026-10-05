import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Framer } from '../extension/src/adapters/audio/framer.js';

const SR = 16_000;

function collect(options = {}) {
  const frames = [];
  const framer = new Framer({
    frameSize: 400,
    hopSize: 160,
    sampleRate: SR,
    onFrame: (frame, tMs) => frames.push({ frame, tMs }),
    ...options,
  });
  return { framer, frames };
}

/** Rampa 0,1,2,… — pozwala sprawdzić, że próbki nie gubią się ani nie dublują. */
const ramp = (n, start = 0) => Float32Array.from({ length: n }, (_, i) => start + i);

test('tnie strumień na nachodzące ramki o właściwym skoku', () => {
  const { framer, frames } = collect();
  framer.push(ramp(1600));

  // (1600 - 400) / 160 + 1 = 8 pełnych ramek
  assert.equal(frames.length, 8);
  assert.equal(frames[0].frame.length, 400);
  assert.equal(frames[0].frame[0], 0);
  assert.equal(frames[1].frame[0], 160, 'druga ramka startuje o hopSize dalej');
  assert.equal(frames[7].frame[0], 7 * 160);
});

test('znaczniki czasu liczone są z numeru próbki', () => {
  const { framer, frames } = collect({ epochMs: 1_000_000 });
  framer.push(ramp(16_400)); // sekunda + jedna pełna ramka

  assert.equal(frames[0].tMs, 1_000_000);
  assert.equal(frames[1].tMs, 1_000_000 + 10, 'skok 160 próbek = 10 ms');
  // Ramka 100 zaczyna się na próbce 16 000, czyli równo sekundę po starcie.
  assert.equal(frames[100].tMs, 1_000_000 + 1000);
});

test('paczki o dowolnej długości dają ten sam wynik co jedna duża', () => {
  const whole = collect();
  whole.framer.push(ramp(4000));

  const chunked = collect();
  const signal = ramp(4000);
  let offset = 0;
  for (const size of [128, 128, 300, 1, 999, 1444, 1000]) {
    chunked.framer.push(signal.subarray(offset, Math.min(offset + size, signal.length)));
    offset += size;
  }

  assert.equal(chunked.frames.length, whole.frames.length);
  for (let i = 0; i < whole.frames.length; i++) {
    assert.deepEqual(Array.from(chunked.frames[i].frame), Array.from(whole.frames[i].frame), `ramka ${i}`);
    assert.equal(chunked.frames[i].tMs, whole.frames[i].tMs);
  }
});

test('paczka dłuższa niż bufor wewnętrzny nie gubi próbek', () => {
  const { framer, frames } = collect();
  framer.push(ramp(100_000));
  assert.equal(frames.length, Math.floor((100_000 - 400) / 160) + 1);
  const last = frames.at(-1);
  assert.equal(last.frame[0], (frames.length - 1) * 160);
});

test('za mało próbek na ramkę = brak wyjścia', () => {
  const { framer, frames } = collect();
  framer.push(ramp(399));
  assert.equal(frames.length, 0);
  framer.push(ramp(1, 399));
  assert.equal(frames.length, 1);
});

test('reset czyści bufor i zegar próbek', () => {
  const { framer, frames } = collect();
  framer.push(ramp(1600));
  framer.reset();
  frames.length = 0;
  framer.push(ramp(400));
  assert.equal(frames.length, 1);
  assert.equal(frames[0].tMs, 0);
});

test('odrzuca bezsensowną konfigurację', () => {
  assert.throws(() => new Framer({ frameSize: 0, hopSize: 10, sampleRate: SR, onFrame: () => {} }), /dodatnie/);
  assert.throws(() => new Framer({ frameSize: 100, hopSize: 200, sampleRate: SR, onFrame: () => {} }), /hopSize/);
});
