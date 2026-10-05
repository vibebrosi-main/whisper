import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AudioAdapter, SOURCE_LABELS } from '../extension/src/adapters/audio/index.js';
import {
  Recognizer,
  availability,
  install,
  isSupported,
  resolveMode,
  ModelWatcher,
} from '../extension/src/adapters/audio/asr.js';
import { TranscriptStore } from '../extension/src/core/transcript.js';

const T0 = 5_000_000;

/** Atrapa SpeechRecognition zgodna z API Chrome. */
class FakeSpeechRecognition {
  static instances = [];
  static available = async () => 'available';
  static install = async () => true;

  constructor() {
    this.started = false;
    this.results = [];
    FakeSpeechRecognition.instances.push(this);
  }

  start(track) {
    if (track && track.readyState !== 'live') throw new Error('InvalidStateError');
    this.track = track ?? null;
    this.started = true;
  }

  abort() {
    this.started = false;
  }

  /** Emituje wynik tak, jak robi to przeglądarka. */
  emit(index, transcript, isFinal) {
    this.results[index] = Object.assign([{ transcript, confidence: 0.9 }], { isFinal });
    this.results.length = Math.max(this.results.length, index + 1);
    this.onresult?.({ resultIndex: index, results: this.results });
  }

  finish() {
    this.started = false;
    this.onend?.();
  }

  fail(error) {
    this.onerror?.({ error });
  }
}

function scope() {
  FakeSpeechRecognition.instances = [];
  return { SpeechRecognition: FakeSpeechRecognition };
}

/** Diaryzator-atrapa: zwraca z góry ustalonego mówcę. */
function fakeDiarizer(speakerFor = () => 0) {
  return {
    speakerCount: 2,
    pushFrame: () => null,
    flush: () => {},
    dominantSpeaker: (from, to) => speakerFor(from, to),
  };
}

function setup({ speakerFor, source = 'tab' } = {}) {
  const store = new TranscriptStore({ startedAt: T0, silenceMs: 100_000, mergeGapMs: 0 });
  let clock = T0;
  const adapter = new AudioAdapter({
    store,
    source,
    diarizer: fakeDiarizer(speakerFor),
    recognizer: new Recognizer({ scope: scope(), now: () => clock }),
    now: () => clock,
  });
  return { store, adapter, tick: (ms) => (clock = T0 + ms) };
}

test('etykiety mówców zależą od źródła', () => {
  assert.equal(SOURCE_LABELS.tab(0), 'Rozmówca 1');
  assert.equal(SOURCE_LABELS.tab(2), 'Rozmówca 3');
  assert.equal(SOURCE_LABELS.mic(0), 'Ty');
  assert.equal(SOURCE_LABELS.mic(1), 'Osoba obok 1');
});

test('wyniki interim rosną w jeden segment, final go domyka', () => {
  const { store, adapter, tick } = setup();
  adapter.start();
  tick(1000);
  adapter.handleResult({ epoch: 1, index: 0, transcript: 'Dzień', isFinal: false, at: T0 + 1000 });
  tick(1600);
  adapter.handleResult({ epoch: 1, index: 0, transcript: 'Dzień dobry', isFinal: false, at: T0 + 1600 });
  tick(2200);
  adapter.handleResult({ epoch: 1, index: 0, transcript: 'Dzień dobry państwu', isFinal: true, at: T0 + 2200 });

  assert.equal(store.segments.length, 1);
  assert.equal(store.segments[0].text, 'Dzień dobry państwu');
  assert.equal(store.segments[0].speaker, 'Rozmówca 1');
  assert.equal(store.segments[0].final, true);
});

test('różni mówcy z diaryzacji trafiają do osobnych segmentów', () => {
  let who = 0;
  const { store, adapter, tick } = setup({ speakerFor: () => who });
  adapter.start();

  tick(1000);
  adapter.handleResult({ epoch: 1, index: 0, transcript: 'Pytanie od pierwszego', isFinal: true, at: T0 + 1000 });
  who = 1;
  tick(4000);
  adapter.handleResult({ epoch: 1, index: 1, transcript: 'Odpowiedź od drugiego', isFinal: true, at: T0 + 4000 });

  assert.deepEqual(
    store.segments.map((s) => [s.speaker, s.text]),
    [
      ['Rozmówca 1', 'Pytanie od pierwszego'],
      ['Rozmówca 2', 'Odpowiedź od drugiego'],
    ],
  );
});

test('mówca ustalony raz nie zmienia się w trakcie wypowiedzi', () => {
  let who = 0;
  const { store, adapter, tick } = setup({ speakerFor: () => who });
  adapter.start();
  tick(1000);
  adapter.handleResult({ epoch: 1, index: 0, transcript: 'zaczynam', isFinal: false, at: T0 + 1000 });
  who = 1; // diaryzator się rozmyślił w połowie
  tick(1500);
  adapter.handleResult({ epoch: 1, index: 0, transcript: 'zaczynam i kończę', isFinal: true, at: T0 + 1500 });

  assert.equal(store.segments.length, 1);
  assert.equal(store.segments[0].speaker, 'Rozmówca 1');
});

test('brak rozpoznanego mówcy nie gubi tekstu', () => {
  const { store, adapter, tick } = setup({ speakerFor: () => null });
  adapter.start();
  tick(1000);
  adapter.handleResult({ epoch: 1, index: 0, transcript: 'ktoś coś mówi', isFinal: true, at: T0 + 1000 });
  assert.equal(store.segments[0].speaker, 'Nieznany');
  assert.equal(store.segments[0].text, 'ktoś coś mówi');
});

test('restart rozpoznawania nie skleja wyników o tym samym indeksie', () => {
  const { store, adapter, tick } = setup();
  adapter.start();
  tick(1000);
  adapter.handleResult({ epoch: 1, index: 0, transcript: 'pierwsze zdanie', isFinal: true, at: T0 + 1000 });
  tick(9000);
  // Po wznowieniu Chrome numeruje wyniki od zera.
  adapter.handleResult({ epoch: 2, index: 0, transcript: 'drugie zdanie', isFinal: true, at: T0 + 9000 });

  assert.deepEqual(store.segments.map((s) => s.text), ['pierwsze zdanie', 'drugie zdanie']);
});

test('pusty transkrypt jest ignorowany', () => {
  const { store, adapter } = setup();
  adapter.start();
  assert.equal(adapter.handleResult({ epoch: 1, index: 0, transcript: '   ', isFinal: false, at: T0 }), null);
  assert.equal(store.isEmpty, true);
});

test('Recognizer startuje, przekazuje ścieżkę audio i wznawia się po onend', () => {
  const testScope = scope();
  const track = { kind: 'audio', readyState: 'live' };
  const seen = [];
  const recognizer = new Recognizer({
    scope: testScope,
    lang: 'pl-PL',
    onResult: (r) => seen.push(r),
    now: () => T0,
  });

  recognizer.start(track);
  const first = FakeSpeechRecognition.instances.at(-1);
  assert.equal(first.started, true);
  assert.equal(first.track, track);
  assert.equal(first.lang, 'pl-PL');
  assert.equal(first.continuous, true);
  assert.equal(first.interimResults, true);
  assert.equal(first.processLocally, true);

  first.emit(0, 'test', true);
  assert.equal(seen.length, 1);
  assert.deepEqual(
    { epoch: seen[0].epoch, index: seen[0].index, transcript: seen[0].transcript, isFinal: seen[0].isFinal },
    { epoch: 1, index: 0, transcript: 'test', isFinal: true },
  );

  recognizer.stop();
  assert.equal(recognizer.running, false);
});

test('Recognizer nie wznawia się po błędzie uprawnień', () => {
  const testScope = scope();
  const errors = [];
  const recognizer = new Recognizer({ scope: testScope, onError: (e) => errors.push(e.message) });
  recognizer.start();
  FakeSpeechRecognition.instances.at(-1).fail('no-speech');
  assert.equal(errors.length, 0, 'no-speech to normalny bieg rzeczy');

  FakeSpeechRecognition.instances.at(-1).fail('not-allowed');
  assert.match(errors[0], /not-allowed/);
  recognizer.stop();
});

test('availability / install / isSupported obsługują brak API', async () => {
  const testScope = scope();
  assert.equal(isSupported(testScope), true);
  assert.equal(await availability('pl-PL', testScope), 'available');
  assert.equal(await install('pl-PL', testScope), true);

  const empty = {};
  assert.equal(isSupported(empty), false);
  assert.equal(await availability('pl-PL', empty), 'unsupported');
  assert.equal(await install('pl-PL', empty), false);
});

/* ---------- wybór trybu rozpoznawania ---------- */

/** Atrapa z konfigurowalnym stanem modelu lokalnego. */
function modeScope({ availableResult = 'available', installResult = false, hasApi = true } = {}) {
  if (!hasApi) return {};
  let state = availableResult;
  class Ctor {
    static available = async () => state;
    static install = async () => {
      if (installResult) state = 'available';
      return installResult;
    };
    start() {}
    abort() {}
  }
  return { SpeechRecognition: Ctor };
}

test('resolveMode wybiera model lokalny, gdy jest gotowy', async () => {
  const mode = await resolveMode({ lang: 'pl-PL', scope: modeScope({ availableResult: 'available' }) });
  assert.deepEqual(mode, { processLocally: true, availability: 'available', reason: 'local' });
});

test('resolveMode próbuje doinstalować model i używa go po sukcesie', async () => {
  const mode = await resolveMode({
    lang: 'pl-PL',
    scope: modeScope({ availableResult: 'downloadable', installResult: true }),
  });
  assert.equal(mode.processLocally, true);
  assert.equal(mode.reason, 'local');
});

test('bez modelu i bez zgody na chmurę zgłasza brak modelu, nie cichnie', async () => {
  const mode = await resolveMode({
    lang: 'pl-PL',
    allowCloud: false,
    scope: modeScope({ availableResult: 'downloadable', installResult: false }),
  });
  assert.equal(mode.reason, 'model-missing');
  assert.equal(mode.processLocally, true, 'nie schodzimy do chmury bez zgody');
});

test('zgoda na chmurę przełącza rozpoznawanie, gdy modelu nie ma', async () => {
  const mode = await resolveMode({
    lang: 'pl-PL',
    allowCloud: true,
    scope: modeScope({ availableResult: 'downloadable', installResult: false }),
  });
  assert.deepEqual(mode, { processLocally: false, availability: 'downloadable', reason: 'cloud' });
});

test('brak Web Speech API jest raportowany osobno', async () => {
  const mode = await resolveMode({ lang: 'pl-PL', scope: modeScope({ hasApi: false }) });
  assert.equal(mode.reason, 'no-api');
  assert.equal(mode.availability, 'unsupported');
});

test('language-not-supported zatrzymuje pętlę restartów', () => {
  const testScope = scope();
  const errors = [];
  const recognizer = new Recognizer({ scope: testScope, onError: (e) => errors.push(e.message) });
  recognizer.start();
  const before = FakeSpeechRecognition.instances.length;

  FakeSpeechRecognition.instances.at(-1).fail('language-not-supported');
  FakeSpeechRecognition.instances.at(-1).finish();

  assert.match(errors[0], /language-not-supported/);
  assert.equal(FakeSpeechRecognition.instances.length, before, 'brak nowego przebiegu');
  recognizer.stop();
});

test('ModelWatcher woła onReady dopiero gdy model jest gotowy', async () => {
  let state = 'downloadable';
  const watcherScope = { SpeechRecognition: class { static available = async () => state; } };
  let ready = 0;
  const watcher = new ModelWatcher({
    lang: 'pl-PL',
    intervalMs: 5,
    scope: watcherScope,
    onReady: () => ready++,
  }).start();

  await new Promise((r) => setTimeout(r, 30));
  assert.equal(ready, 0);

  state = 'available';
  await new Promise((r) => setTimeout(r, 40));
  watcher.stop();
  assert.equal(ready, 1, 'dokładnie raz — watcher zatrzymuje się sam');
});

/* ---------- regresje z realnej sesji na YouTube ---------- */

test('poprawiane hipotezy ASR podmieniają tekst, nie doklejają się', () => {
  const { store, adapter, tick } = setup();
  adapter.start();

  // Prawdziwy ciąg migawek Web Speech dla jednego indeksu wyniku:
  // rozpoznawanie rewiduje początek zdania, nie tylko dopisuje ogon.
  const snapshots = [
    'ja czuję',
    'ja czuję czuję st',
    'Czuję stres',
    'Czuję stres nawet',
    'Czuję stres nawet jak tutaj idziemy tylko nagrywać odcinek',
  ];
  snapshots.forEach((transcript, i) => {
    tick(1000 + i * 400);
    adapter.handleResult({ epoch: 1, index: 0, transcript, isFinal: false, at: T0 + 1000 + i * 400 });
  });

  assert.equal(store.segments.length, 1);
  assert.equal(store.segments[0].text, snapshots.at(-1));
  assert.ok(!store.segments[0].text.includes('czuję czuję'), 'brak zdublowanych słów');
});

test('ponowna emisja domkniętego wyniku nie tworzy drugiego segmentu', () => {
  const { store, adapter, tick } = setup();
  adapter.start();

  tick(1000);
  adapter.handleResult({ epoch: 1, index: 0, transcript: 'pełna wypowiedź', isFinal: true, at: T0 + 1000 });
  assert.equal(store.segments.length, 1);

  // Chrome potrafi wysłać ten sam indeks jeszcze raz razem z kolejnym wynikiem.
  tick(1400);
  adapter.handleResult({ epoch: 1, index: 0, transcript: 'pełna wypowiedź', isFinal: true, at: T0 + 1400 });
  tick(1800);
  adapter.handleResult({ epoch: 1, index: 0, transcript: 'pełna wypowiedź poprawiona', isFinal: false, at: T0 + 1800 });

  assert.equal(store.segments.length, 1, 'żadnych duplikatów');
  assert.equal(store.segments[0].text, 'pełna wypowiedź');
});

test('równolegle żywe wyniki o różnych indeksach zostają osobnymi segmentami', () => {
  const { store, adapter, tick } = setup();
  adapter.start();

  // Chrome trzyma results[0] domknięty i results[1] w trakcie.
  tick(1000);
  adapter.handleResult({ epoch: 1, index: 0, transcript: 'pierwsza myśl', isFinal: true, at: T0 + 1000 });
  tick(2000);
  adapter.handleResult({ epoch: 1, index: 1, transcript: 'druga myśl', isFinal: false, at: T0 + 2000 });
  tick(2400);
  adapter.handleResult({ epoch: 1, index: 1, transcript: 'druga myśl w całości', isFinal: true, at: T0 + 2400 });

  assert.deepEqual(store.segments.map((s) => s.text), ['pierwsza myśl', 'druga myśl w całości']);
});

test('tryb replace nie psuje sklejania napisów Meet', () => {
  // Ten sam store, dwa źródła o różnej semantyce migawek.
  const store = new TranscriptStore({ startedAt: T0, silenceMs: 100_000, mergeGapMs: 0 });
  store.upsert({ key: 'meet:1', speaker: 'Anna', text: 'mamy trzy tematy', at: T0 });
  store.upsert({ key: 'meet:1', speaker: 'Anna', text: 'trzy tematy do omówienia', at: T0 + 400 });
  store.upsert({ key: 'asr:1', speaker: 'Rozmówca 1', text: 'ja czuję czuję', at: T0 + 500, replace: true });
  store.upsert({ key: 'asr:1', speaker: 'Rozmówca 1', text: 'Czuję stres', at: T0 + 900, replace: true });

  assert.equal(store.segments[0].text, 'mamy trzy tematy do omówienia', 'Meet nadal scala okno');
  assert.equal(store.segments[1].text, 'Czuję stres', 'ASR podmienia');
});
