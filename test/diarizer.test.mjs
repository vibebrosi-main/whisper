import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Vad } from '../extension/src/adapters/audio/vad.js';
import {
  Diarizer,
  SpeakerTracker,
  embedFrames,
  cosineSimilarity,
  l2Normalize,
} from '../extension/src/adapters/audio/diarizer.js';
import { MfccExtractor } from '../extension/src/adapters/audio/features.js';

const SR = 16_000;
const FRAME = 400; // 25 ms
const HOP = 160; // 10 ms

/** Deterministyczny generator szumu. */
function noise(seed) {
  let state = seed;
  return () => {
    state = (state * 1103515245 + 12345) % 2147483648;
    return state / 2147483648 - 0.5;
  };
}

/**
 * Syntetyczny głos: ton krtaniowy f0 + formanty.
 * Różne zestawy formantów = różne barwy = różni „mówcy".
 */
function voice({ f0, formants, seconds, sampleRate = SR, gain = 1, seed = 7 }) {
  const random = noise(seed);
  const length = Math.round(seconds * sampleRate);
  const out = new Float64Array(length);
  for (let i = 0; i < length; i++) {
    const t = i / sampleRate;
    // Lekka modulacja amplitudy imituje sylaby.
    const envelope = 0.7 + 0.3 * Math.sin(2 * Math.PI * 4 * t);
    let value = 0.4 * Math.sin(2 * Math.PI * f0 * t);
    for (const [freq, amp] of formants) value += amp * Math.sin(2 * Math.PI * freq * t + freq);
    out[i] = gain * envelope * value + 0.004 * random();
  }
  return out;
}

function silence(seconds, sampleRate = SR, seed = 3) {
  const random = noise(seed);
  const out = new Float64Array(Math.round(seconds * sampleRate));
  for (let i = 0; i < out.length; i++) out[i] = 0.0015 * random();
  return out;
}

function concat(chunks) {
  const total = chunks.reduce((acc, c) => acc + c.length, 0);
  const out = new Float64Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

/** Przepuszcza sygnał przez diaryzator ramka po ramce. */
function run(diarizer, signal, sampleRate = SR) {
  for (let start = 0; start + FRAME <= signal.length; start += HOP) {
    diarizer.pushFrame(signal.subarray(start, start + FRAME), (start / sampleRate) * 1000);
  }
  diarizer.flush((signal.length / sampleRate) * 1000);
}

const ANNA = { f0: 205, formants: [[520, 0.30], [2350, 0.26], [3100, 0.12]] };
const JAN = { f0: 105, formants: [[330, 0.32], [1100, 0.24], [2400, 0.10]] };

test('l2Normalize i cosineSimilarity', () => {
  const v = l2Normalize(Float64Array.from([3, 4]));
  assert.ok(Math.abs(Math.hypot(v[0], v[1]) - 1) < 1e-12);
  assert.ok(Math.abs(cosineSimilarity(v, v) - 1) < 1e-12);

  const orthogonal = l2Normalize(Float64Array.from([-4, 3]));
  assert.ok(Math.abs(cosineSimilarity(v, orthogonal)) < 1e-12);
});

test('embedFrames zwraca znormalizowany wektor średnia+odchylenie', () => {
  const frames = [Float64Array.from([1, 2]), Float64Array.from([3, 4])];
  const embedding = embedFrames(frames);
  assert.equal(embedding.length, 4);
  assert.ok(Math.abs(Math.hypot(...embedding) - 1) < 1e-12);
  assert.equal(embedFrames([]), null);
});

test('SpeakerTracker zakłada nowego mówcę dopiero poniżej progu', () => {
  const tracker = new SpeakerTracker({ threshold: 0.9 });
  const a = l2Normalize(Float64Array.from([1, 0, 0]));
  const aPrim = l2Normalize(Float64Array.from([0.97, 0.24, 0]));
  const b = l2Normalize(Float64Array.from([0, 0, 1]));

  assert.deepEqual(tracker.assign(a), { index: 0, similarity: -Infinity, isNew: true });
  assert.equal(tracker.assign(aPrim).index, 0, 'podobny głos to ten sam mówca');
  const second = tracker.assign(b);
  assert.equal(second.index, 1);
  assert.equal(second.isNew, true);
  assert.equal(tracker.count, 2);
});

test('SpeakerTracker respektuje limit mówców', () => {
  const tracker = new SpeakerTracker({ threshold: 0.99, maxSpeakers: 2 });
  tracker.assign(l2Normalize(Float64Array.from([1, 0, 0])));
  tracker.assign(l2Normalize(Float64Array.from([0, 1, 0])));
  const third = tracker.assign(l2Normalize(Float64Array.from([0, 0, 1])));
  assert.equal(tracker.count, 2);
  assert.equal(third.isNew, false);
});

test('VAD otwiera i zamyka wypowiedź z histerezą', () => {
  const vad = new Vad({ thresholdDb: 10, onsetFrames: 3, hangoverFrames: 5, initialFloorDb: -60 });
  for (let i = 0; i < 20; i++) vad.push(-60);
  assert.equal(vad.speaking, false);

  assert.equal(vad.push(-20).speaking, false, 'jedna głośna ramka to za mało');
  vad.push(-20);
  const third = vad.push(-20);
  assert.equal(third.speaking, true);
  assert.equal(third.started, true);

  for (let i = 0; i < 4; i++) assert.equal(vad.push(-60).speaking, true, 'hangover trzyma wypowiedź');
  assert.equal(vad.push(-60).ended, true);
});

test('VAD adaptuje się do stałego hałasu w tle', () => {
  const vad = new Vad({ thresholdDb: 12, onsetFrames: 3, subwindowFrames: 50, subwindows: 6, initialFloorDb: -70 });

  // Wentylator startuje: na początku wygląda jak mowa, bo podłoga jest niska.
  for (let i = 0; i < 10; i++) vad.push(-40);
  assert.equal(vad.speaking, true, 'zanim się zaadaptuje, hałas wygląda jak mowa');

  // Po zapełnieniu bufora historii podłoga siada na poziomie hałasu.
  for (let i = 0; i < 400; i++) vad.push(-40);
  assert.ok(vad.noiseFloorDb > -45, `podłoga podniosła się do ${vad.noiseFloorDb.toFixed(1)} dB`);
  assert.equal(vad.speaking, false, 'stały szum przestaje być mową');

  // Realna mowa ponad tym hałasem nadal się przebija.
  for (let i = 0; i < 5; i++) vad.push(-20);
  assert.equal(vad.speaking, true);
});

test('VAD nie ucina długiej nieprzerwanej wypowiedzi', () => {
  const vad = new Vad({ thresholdDb: 12, onsetFrames: 3, hangoverFrames: 25, initialFloorDb: -70 });
  let dropouts = 0;
  // 10 sekund mowy z naturalnymi przerwami międzysylabowymi.
  for (let i = 0; i < 1000; i++) {
    const syllablePause = i % 25 < 4;
    const state = vad.push(syllablePause ? -58 : -25);
    if (i > 10 && !state.speaking) dropouts++;
  }
  assert.equal(dropouts, 0, `wypowiedź urwana ${dropouts} razy`);
});

test('diaryzacja rozdziela dwa wyraźnie różne głosy', () => {
  const diarizer = new Diarizer({ sampleRate: SR, threshold: 0.82, initialFloorDb: -70 });
  const signal = concat([
    silence(0.3),
    voice({ ...ANNA, seconds: 1.5, seed: 11 }),
    silence(0.5),
    voice({ ...JAN, seconds: 1.5, seed: 12 }),
    silence(0.5),
    voice({ ...ANNA, seconds: 1.2, seed: 13 }),
    silence(0.4),
  ]);

  run(diarizer, signal);

  assert.equal(diarizer.turns.length, 3, `tury: ${JSON.stringify(diarizer.turns)}`);
  assert.equal(diarizer.speakerCount, 2, 'dokładnie dwóch mówców');

  const [first, second, third] = diarizer.turns;
  assert.equal(first.speaker, third.speaker, 'Anna rozpoznana ponownie');
  assert.notEqual(first.speaker, second.speaker, 'Jan to inny mówca');
});

test('ten sam głos nagrany dwa razy nie rozdwaja mówcy', () => {
  const diarizer = new Diarizer({ sampleRate: SR, threshold: 0.82, initialFloorDb: -70 });
  const signal = concat([
    silence(0.3),
    voice({ ...ANNA, seconds: 1.2, seed: 21 }),
    silence(0.5),
    voice({ ...ANNA, seconds: 1.2, seed: 22, gain: 0.5 }), // ciszej — nie może zmylić
    silence(0.3),
  ]);

  run(diarizer, signal);
  assert.equal(diarizer.speakerCount, 1, 'głośność nie tworzy nowego mówcy');
  assert.equal(diarizer.turns.length, 2);
});

test('dominantSpeaker wiąże okno czasu z mówcą', () => {
  const diarizer = new Diarizer({ sampleRate: SR, threshold: 0.82, initialFloorDb: -70 });
  const signal = concat([
    silence(0.3),
    voice({ ...ANNA, seconds: 1.5, seed: 31 }),
    silence(0.5),
    voice({ ...JAN, seconds: 1.5, seed: 32 }),
    silence(0.3),
  ]);
  run(diarizer, signal);

  const [anna, jan] = diarizer.turns;
  assert.equal(diarizer.dominantSpeaker(anna.startMs, anna.endMs), anna.speaker);
  assert.equal(diarizer.dominantSpeaker(jan.startMs, jan.endMs), jan.speaker);
  assert.equal(diarizer.dominantSpeaker(0, 100), null, 'cisza nie ma mówcy');
});

test('sama cisza nie produkuje ani mówców, ani tur', () => {
  const diarizer = new Diarizer({ sampleRate: SR, initialFloorDb: -70 });
  run(diarizer, silence(2));
  assert.equal(diarizer.turns.length, 0);
  assert.equal(diarizer.speakerCount, 0);
});
