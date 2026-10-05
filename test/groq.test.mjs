import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  GroqTranscriber,
  TranscriptionQueue,
  GroqError,
  GROQ_MODELS,
  DEFAULT_MODEL,
} from '../extension/src/adapters/audio/groq.js';
import { GroqAdapter } from '../extension/src/adapters/audio/groq-adapter.js';
import { TranscriptStore } from '../extension/src/core/transcript.js';

const T0 = 7_000_000;
const wav = () => new ArrayBuffer(2048);

/** Atrapa fetch: kolejka odpowiedzi + zapis wykonanych żądań. */
function fakeFetch(responses) {
  const calls = [];
  const queue = [...responses];
  const impl = async (url, init) => {
    calls.push({ url, init });
    const next = queue.length > 1 ? queue.shift() : queue[0];
    if (next instanceof Error) throw next;
    return {
      ok: next.status >= 200 && next.status < 300,
      status: next.status,
      json: async () => next.body,
    };
  };
  impl.calls = calls;
  return impl;
}

const noSleep = async () => {};

test('katalog modeli ma sensowne domyślne', () => {
  assert.ok(GROQ_MODELS.some((m) => m.id === DEFAULT_MODEL));
  assert.equal(DEFAULT_MODEL, 'whisper-large-v3-turbo');
});

test('transcribe wysyła poprawny multipart i parsuje verbose_json', async () => {
  const fetchImpl = fakeFetch([
    {
      status: 200,
      body: {
        text: 'Czuję stres nawet jak tutaj idziemy.',
        segments: [
          { start: 0.2, end: 1.8, text: ' Czuję stres ' },
          { start: 1.8, end: 3.1, text: 'nawet jak tutaj idziemy.' },
          { start: 3.1, end: 3.2, text: '   ' },
        ],
      },
    },
  ]);

  const transcriber = new GroqTranscriber({ apiKey: 'gsk_test', language: 'pl', fetchImpl });
  const result = await transcriber.transcribe(wav());

  assert.equal(result.text, 'Czuję stres nawet jak tutaj idziemy.');
  assert.equal(result.segments.length, 2, 'puste segmenty odsiane');
  assert.deepEqual(result.segments[0], { start: 0.2, end: 1.8, text: 'Czuję stres' });

  const { init } = fetchImpl.calls[0];
  assert.equal(init.headers.Authorization, 'Bearer gsk_test');
  assert.equal(init.body.get('model'), DEFAULT_MODEL);
  assert.equal(init.body.get('response_format'), 'verbose_json');
  assert.equal(init.body.get('language'), 'pl');
});

test('brak klucza API jest błędem od razu, nie po pierwszym żądaniu', () => {
  assert.throws(() => new GroqTranscriber({}), /klucza API/);
});

test('błędny klucz nie jest ponawiany', async () => {
  const fetchImpl = fakeFetch([{ status: 401, body: { error: { message: 'invalid' } } }]);
  const transcriber = new GroqTranscriber({ apiKey: 'zły', fetchImpl, sleep: noSleep });

  await assert.rejects(() => transcriber.transcribe(wav()), (error) => {
    assert.ok(error instanceof GroqError);
    assert.equal(error.code, 'bad-key');
    return true;
  });
  assert.equal(fetchImpl.calls.length, 1, 'bez ponawiania');
});

test('limit zapytań jest ponawiany z narastającą zwłoką', async () => {
  const fetchImpl = fakeFetch([
    { status: 429, body: {} },
    { status: 429, body: {} },
    { status: 200, body: { text: 'udało się', segments: [] } },
  ]);
  const delays = [];
  const transcriber = new GroqTranscriber({
    apiKey: 'gsk_test',
    fetchImpl,
    sleep: async (ms) => delays.push(ms),
  });

  const result = await transcriber.transcribe(wav());
  assert.equal(result.text, 'udało się');
  assert.equal(fetchImpl.calls.length, 3);
  assert.deepEqual(delays, [700, 1400], 'wykładnicze wycofanie');
});

test('błąd sieci jest ponawiany, a po wyczerpaniu prób zgłaszany', async () => {
  const fetchImpl = fakeFetch([new Error('ECONNRESET')]);
  const transcriber = new GroqTranscriber({ apiKey: 'gsk_test', fetchImpl, maxRetries: 2, sleep: noSleep });

  await assert.rejects(() => transcriber.transcribe(wav()), /Błąd sieci/);
  assert.equal(fetchImpl.calls.length, 3, 'pierwsza próba + 2 ponowienia');
});

test('za duży plik jest odrzucany bez ruszania sieci', async () => {
  const fetchImpl = fakeFetch([{ status: 200, body: {} }]);
  const transcriber = new GroqTranscriber({ apiKey: 'gsk_test', fetchImpl });
  await assert.rejects(() => transcriber.transcribe(new ArrayBuffer(26 * 1024 * 1024)), /25 MB/);
  assert.equal(fetchImpl.calls.length, 0);
});

test('kolejka zachowuje kolejność wejścia mimo różnych czasów odpowiedzi', async () => {
  const order = [];
  const transcriber = {
    transcribe: async (buffer) => {
      const id = new DataView(buffer).getUint8(0);
      // Pierwsze żądanie odpowiada najwolniej.
      await new Promise((r) => setTimeout(r, id === 1 ? 30 : 1));
      return { text: `tekst ${id}`, segments: [] };
    },
  };
  const queue = new TranscriptionQueue({ transcriber, onResult: (r) => order.push(r.text) });

  for (const id of [1, 2, 3]) {
    const buffer = new ArrayBuffer(4);
    new DataView(buffer).setUint8(0, id);
    queue.enqueue({ wav: buffer, meta: { id } });
  }
  await queue.drain();

  assert.deepEqual(order, ['tekst 1', 'tekst 2', 'tekst 3']);
});

test('kolejka odrzuca nadmiar zamiast rosnąć bez końca', async () => {
  const transcriber = { transcribe: async () => new Promise((r) => setTimeout(() => r({ text: 'x', segments: [] }), 5)) };
  const queue = new TranscriptionQueue({ transcriber, onResult: () => {}, maxPending: 2 });

  assert.equal(queue.enqueue({ wav: wav(), meta: {} }), true);
  assert.equal(queue.enqueue({ wav: wav(), meta: {} }), true);
  assert.equal(queue.enqueue({ wav: wav(), meta: {} }), false, 'trzecie ponad limit');
  assert.equal(queue.dropped, 1);
  await queue.drain();
});

/* ---------- adapter ---------- */

/** Diaryzator-atrapa: pozwala ręcznie zamykać tury. */
function fakeDiarizer() {
  return {
    extractor: { hopSize: 160 },
    speakerCount: 2,
    onTurn: () => {},
    pushFrame: () => null,
    flush: () => {},
    dominantSpeaker: () => 0,
  };
}

function setupAdapter({ transcribe, maxPending } = {}) {
  const store = new TranscriptStore({ startedAt: T0, silenceMs: 100_000, mergeGapMs: 0 });
  const diarizer = fakeDiarizer();
  const transcriber = { transcribe: transcribe ?? (async () => ({ text: 'rozpoznany tekst', segments: [] })) };
  const adapter = new GroqAdapter({
    store,
    source: 'tab',
    epochMs: T0,
    diarizer,
    transcriber,
    queue: new TranscriptionQueue({
      transcriber,
      onResult: (r, m) => adapter._onResult(r, m),
      onError: (e, m) => adapter._onError(e, m),
      maxPending,
    }),
  });
  return { store, diarizer, adapter };
}

test('tura mówcy staje się jednym żądaniem i jednym segmentem', async () => {
  const { store, diarizer, adapter } = setupAdapter();
  adapter.start();
  // Wypełniamy bufor audio, żeby było co wyciąć.
  for (let i = 0; i < 200; i++) {
    adapter.pushFrame(new Float32Array(400).fill(0.1), T0 + i * 10);
  }

  diarizer.onTurn({ speaker: 1, startMs: T0 + 200, endMs: T0 + 1600 });
  await adapter.queue.drain();

  assert.equal(store.segments.length, 1);
  assert.equal(store.segments[0].speaker, 'Rozmówca 2', 'etykieta prosto z diaryzacji');
  assert.equal(store.segments[0].text, 'rozpoznany tekst');
});

test('placeholder pojawia się natychmiast, zanim wróci odpowiedź', async () => {
  let release;
  const gate = new Promise((r) => (release = r));
  const { store, diarizer, adapter } = setupAdapter({
    transcribe: async () => {
      await gate;
      return { text: 'gotowe', segments: [] };
    },
  });
  adapter.start();
  for (let i = 0; i < 200; i++) adapter.pushFrame(new Float32Array(400).fill(0.1), T0 + i * 10);

  diarizer.onTurn({ speaker: 0, startMs: T0 + 200, endMs: T0 + 1600 });
  assert.equal(store.segments.length, 1, 'UI nie milczy w trakcie żądania');
  assert.equal(store.segments[0].text, '…');

  release();
  await adapter.queue.drain();
  assert.equal(store.segments[0].text, 'gotowe');
});

test('zbyt krótkie tury są pomijane — Groq liczy minimum 10 s za żądanie', () => {
  const { store, diarizer, adapter } = setupAdapter();
  adapter.start();
  for (let i = 0; i < 200; i++) adapter.pushFrame(new Float32Array(400).fill(0.1), T0 + i * 10);

  diarizer.onTurn({ speaker: 0, startMs: T0 + 300, endMs: T0 + 500 }); // 200 ms
  assert.equal(store.segments.length, 0);
  assert.equal(adapter.skipped, 1);
});

test('błąd transkrypcji usuwa placeholder zamiast zostawiać pusty segment', async () => {
  const { store, diarizer, adapter } = setupAdapter({
    transcribe: async () => {
      throw new GroqError('Nieprawidłowy klucz API Groq', { code: 'bad-key' });
    },
  });
  adapter.start();
  for (let i = 0; i < 200; i++) adapter.pushFrame(new Float32Array(400).fill(0.1), T0 + i * 10);

  diarizer.onTurn({ speaker: 0, startMs: T0 + 200, endMs: T0 + 1600 });
  await adapter.queue.drain();

  assert.equal(store.segments.length, 0, 'brak pustego segmentu');
  assert.match(adapter.status.error, /klucz API/);
});

test('status raportuje zaległości kolejki', async () => {
  const { adapter } = setupAdapter();
  adapter.start();
  assert.deepEqual(
    { backend: adapter.status.backend, running: adapter.status.running, pending: adapter.status.pending },
    { backend: 'groq', running: true, pending: 0 },
  );
});
