import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TranscriptStore, UNKNOWN_SPEAKER } from '../extension/src/core/transcript.js';

const T0 = 1_000_000;

function store(options = {}) {
  return new TranscriptStore({ startedAt: T0, silenceMs: 1000, mergeGapMs: 1500, ...options });
}

test('rosnąca wypowiedź to jeden segment', () => {
  const s = store();
  s.upsert({ key: 'a', speaker: 'Anna', text: 'Cześć', at: T0 + 100 });
  s.upsert({ key: 'a', speaker: 'Anna', text: 'Cześć wszystkim', at: T0 + 400 });
  s.finalizeAll(T0 + 500);
  assert.equal(s.segments.length, 1);
  assert.deepEqual(
    s.segments.map((x) => [x.speaker, x.text, x.offsetMs]),
    [['Anna', 'Cześć wszystkim', 100]],
  );
});

test('zmiana mówcy w tym samym bloku DOM tworzy nowy segment', () => {
  const s = store();
  s.upsert({ key: 'a', speaker: 'Anna', text: 'Cześć', at: T0 });
  s.upsert({ key: 'a', speaker: 'Jan', text: 'Hej', at: T0 + 200 });
  s.finalizeAll(T0 + 300);
  assert.deepEqual(
    s.segments.map((x) => x.speaker),
    ['Anna', 'Jan'],
  );
});

test('finalizeIdle domyka dopiero po ciszy', () => {
  const s = store({ silenceMs: 1000 });
  s.upsert({ key: 'a', speaker: 'Anna', text: 'mówię', at: T0 });
  s.finalizeIdle(T0 + 500);
  assert.equal(s.liveCount, 1);
  s.finalizeIdle(T0 + 1200);
  assert.equal(s.liveCount, 0);
  assert.equal(s.segments[0].final, true);
});

test('kolejne segmenty tej samej osoby w oknie mergeGapMs są sklejane', () => {
  const s = store({ silenceMs: 500, mergeGapMs: 2000 });
  s.upsert({ key: 'a', speaker: 'Anna', text: 'Pierwsza myśl.', at: T0 });
  s.dropKey('a', T0 + 100);
  s.upsert({ key: 'b', speaker: 'Anna', text: 'Druga myśl.', at: T0 + 800 });
  s.dropKey('b', T0 + 900);
  assert.equal(s.segments.length, 1);
  assert.equal(s.segments[0].text, 'Pierwsza myśl. Druga myśl.');
});

test('sklejanie nie przeskakuje innego mówcy ani zbyt dużej przerwy', () => {
  const s = store({ silenceMs: 500, mergeGapMs: 1000 });
  s.upsert({ key: 'a', speaker: 'Anna', text: 'A.', at: T0 });
  s.dropKey('a', T0);
  s.upsert({ key: 'b', speaker: 'Jan', text: 'B.', at: T0 + 100 });
  s.dropKey('b', T0 + 100);
  s.upsert({ key: 'c', speaker: 'Anna', text: 'C.', at: T0 + 200 });
  s.dropKey('c', T0 + 200);
  s.upsert({ key: 'd', speaker: 'Anna', text: 'D.', at: T0 + 60_000 });
  s.dropKey('d', T0 + 60_000);
  assert.deepEqual(
    s.segments.map((x) => `${x.speaker}:${x.text}`),
    ['Anna:A.', 'Jan:B.', 'Anna:C.', 'Anna:D.'],
  );
});

test('brak nazwy mówcy nie gubi wypowiedzi', () => {
  const s = store();
  s.upsert({ key: 'a', speaker: null, text: 'ktoś mówi', at: T0 });
  s.finalizeAll(T0 + 10);
  assert.equal(s.segments[0].speaker, UNKNOWN_SPEAKER);
});

test('pusty tekst jest ignorowany', () => {
  const s = store();
  assert.equal(s.upsert({ key: 'a', speaker: 'Anna', text: '   ', at: T0 }), null);
  assert.equal(s.isEmpty, true);
});

test('statystyki mówców w kolejności wystąpienia', () => {
  const s = store({ mergeGapMs: 0 });
  s.upsert({ key: 'a', speaker: 'Anna', text: 'raz dwa trzy', at: T0 });
  s.dropKey('a', T0);
  s.upsert({ key: 'b', speaker: 'Jan', text: 'cztery', at: T0 + 5000 });
  s.dropKey('b', T0 + 5000);
  const stats = s.speakers;
  assert.deepEqual(stats.map((x) => [x.name, x.segments, x.words]), [
    ['Anna', 1, 3],
    ['Jan', 1, 1],
  ]);
});

test('roundtrip JSON zachowuje segmenty', () => {
  const s = store();
  s.upsert({ key: 'a', speaker: 'Anna', text: 'test', at: T0 + 50 });
  s.finalizeAll(T0 + 100);
  const restored = TranscriptStore.fromJSON(s.toJSON());
  assert.deepEqual(
    restored.segments.map((x) => [x.speaker, x.text, x.offsetMs]),
    s.segments.map((x) => [x.speaker, x.text, x.offsetMs]),
  );
});

test('revision rośnie tylko przy realnej zmianie', () => {
  const s = store();
  s.upsert({ key: 'a', speaker: 'Anna', text: 'stabilne', at: T0 });
  const rev = s.revision;
  s.upsert({ key: 'a', speaker: 'Anna', text: 'stabilne', at: T0 + 100 });
  assert.equal(s.revision, rev);
});

test('wiszący blok napisów nie duplikuje domkniętej wypowiedzi', () => {
  const s = store({ silenceMs: 1000, mergeGapMs: 0 });
  s.upsert({ key: 'a', speaker: 'Anna', text: 'to jest cała moja wypowiedź', at: T0 });
  s.finalizeIdle(T0 + 1500);
  assert.equal(s.segments.length, 1);

  // Meet trzyma ten sam blok na ekranie jeszcze kilka sekund.
  for (let i = 1; i <= 10; i++) {
    s.upsert({ key: 'a', speaker: 'Anna', text: 'to jest cała moja wypowiedź', at: T0 + 1500 + i * 500 });
  }
  assert.equal(s.segments.length, 1, 'żadnych duplikatów');
  assert.equal(s.segments[0].text, 'to jest cała moja wypowiedź');
});

test('wznowienie mowy w tym samym bloku zapisuje tylko nową treść', () => {
  const s = store({ silenceMs: 1000, mergeGapMs: 0 });
  s.upsert({ key: 'a', speaker: 'Anna', text: 'pierwsza część wypowiedzi', at: T0 });
  s.finalizeIdle(T0 + 1500);

  // Anna wraca do mówienia, Meet dopisuje do tego samego bloku.
  s.upsert({ key: 'a', speaker: 'Anna', text: 'pierwsza część wypowiedzi i jeszcze druga', at: T0 + 4000 });
  s.finalizeAll(T0 + 6000);

  assert.deepEqual(
    s.segments.map((x) => x.text),
    ['pierwsza część wypowiedzi', 'i jeszcze druga'],
  );
  assert.deepEqual(s.segments.map((x) => x.offsetMs), [0, 4000]);
});

test('inny mówca w wiszącym bloku nie jest blokowany przez pamięć domknięć', () => {
  const s = store({ silenceMs: 1000, mergeGapMs: 0 });
  s.upsert({ key: 'a', speaker: 'Anna', text: 'moja kwestia', at: T0 });
  s.finalizeIdle(T0 + 1500);
  s.upsert({ key: 'a', speaker: 'Jan', text: 'moja kwestia', at: T0 + 2000 });
  s.finalizeAll(T0 + 4000);

  assert.deepEqual(
    s.segments.map((x) => [x.speaker, x.text]),
    [
      ['Anna', 'moja kwestia'],
      ['Jan', 'moja kwestia'],
    ],
  );
});

test('dropKey czyści pamięć domknięć — nowy blok startuje czysto', () => {
  const s = store({ silenceMs: 1000, mergeGapMs: 0 });
  s.upsert({ key: 'a', speaker: 'Anna', text: 'coś powiedziała', at: T0 });
  s.dropKey('a', T0 + 500);
  s.upsert({ key: 'a', speaker: 'Anna', text: 'coś powiedziała', at: T0 + 3000 });
  s.finalizeAll(T0 + 5000);
  assert.equal(s.segments.length, 2);
});

test('discard usuwa segment bez śladu, dropKey tylko go domyka', () => {
  const s = store();
  s.upsert({ key: 'a', speaker: 'Anna', text: 'zostaje', at: T0 });
  s.upsert({ key: 'b', speaker: 'Jan', text: 'znika', at: T0 + 100 });

  s.dropKey('a', T0 + 200);
  assert.equal(s.segments.length, 2);
  assert.equal(s.segments[0].final, true, 'dropKey domyka');

  assert.equal(s.discard('b'), true);
  assert.deepEqual(s.segments.map((x) => x.text), ['zostaje']);
  assert.equal(s.discard('b'), false, 'drugi raz nie ma czego usuwać');
});

test('seal blokuje klucz na dobre, także po discard', () => {
  const s = store();
  s.upsert({ key: 'a', speaker: 'Anna', text: 'w toku', at: T0 });
  s.discard('a');
  s.seal('a', T0 + 100);
  assert.equal(s.upsert({ key: 'a', speaker: 'Anna', text: 'spóźniona odpowiedź', at: T0 + 200 }), null);
  assert.equal(s.isEmpty, true);
});
