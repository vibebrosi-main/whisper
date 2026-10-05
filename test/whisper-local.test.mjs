import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WhisperLocalClient, cleanText, WhisperLocalError } from '../extension/src/adapters/audio/whisper-local.js';
import { StreamingWhisperAdapter } from '../extension/src/adapters/audio/streaming-adapter.js';
import { TranscriptStore } from '../extension/src/core/transcript.js';

const T0 = 9_000_000;

test('cleanText usuwa znaczniki whisper.cpp i łamania linii', () => {
  assert.equal(cleanText(' Dzień dobry,\nzaczynamy.\n'), 'Dzień dobry, zaczynamy.');
  assert.equal(cleanText('[BLANK_AUDIO]'), '');
  assert.equal(cleanText('Tekst [Muzyka] dalej (szum) koniec'), 'Tekst dalej koniec');
  assert.equal(cleanText(null), '');
});

test('klient wysyła WAV i parsuje odpowiedź', async () => {
  const calls = [];
  const client = new WhisperLocalClient({
    language: 'pl',
    fetchImpl: async (url, init) => {
      calls.push({ url, body: init.body });
      return { ok: true, status: 200, json: async () => ({ text: ' Cześć wszystkim.\n' }) };
    },
  });

  const result = await client.transcribe(new Float32Array(16_000));
  assert.equal(result.text, 'Cześć wszystkim.');
  assert.match(calls[0].url, /\/inference$/);
  assert.equal(calls[0].body.get('language'), 'pl');
  assert.equal(calls[0].body.get('temperature'), '0');
  assert.ok(calls[0].body.get('file') instanceof Blob);
});

test('brak serwera daje czytelny błąd z podpowiedzią', async () => {
  const client = new WhisperLocalClient({
    fetchImpl: async () => {
      throw new TypeError('fetch failed');
    },
  });
  await assert.rejects(() => client.transcribe(new Float32Array(1600)), (error) => {
    assert.ok(error instanceof WhisperLocalError);
    assert.equal(error.code, 'offline');
    assert.match(error.message, /npm run whisper/);
    return true;
  });
});

/* ---------- adapter przyrostowy ---------- */

/** Diaryzator-atrapa z ręcznym sterowaniem turami. */
function fakeDiarizer() {
  return {
    extractor: { hopSize: 160 },
    speakerCount: 1,
    currentSpeaker: 0,
    onTurn: () => {},
    onTurnStart: () => {},
    pushFrame: () => 0,
    flush: () => {},
  };
}

function setup({ texts = ['Dzień', 'Dzień dobry', 'Dzień dobry wszystkim'] } = {}) {
  const store = new TranscriptStore({ startedAt: T0, silenceMs: 100_000, mergeGapMs: 0 });
  const diarizer = fakeDiarizer();
  let call = 0;
  const client = {
    transcribe: async () => ({ text: texts[Math.min(call++, texts.length - 1)] }),
  };
  const adapter = new StreamingWhisperAdapter({
    store,
    source: 'tab',
    epochMs: T0,
    diarizer,
    client,
    intervalMs: 100_000, // timer wyłączony — tickujemy ręcznie
  });
  return { store, diarizer, adapter, client, calls: () => call };
}

/** Wypełnia bufor kołowy tak, by było co wyciąć. */
function feed(adapter, seconds = 4) {
  const frames = Math.round((seconds * 1000) / 10);
  for (let i = 0; i < frames; i++) {
    adapter.pushFrame(new Float32Array(400).fill(0.1), T0 + i * 10);
  }
}

test('tekst pojawia się w trakcie mówienia i jest podmieniany', async () => {
  const { store, diarizer, adapter } = setup();
  adapter.start();
  diarizer.onTurnStart({ startMs: T0 + 100 });
  feed(adapter, 4);

  await adapter._tickForTest();
  assert.equal(store.segments.length, 1, 'segment istnieje jeszcze przed końcem wypowiedzi');
  assert.equal(store.segments[0].text, 'Dzień');

  await adapter._tickForTest();
  assert.equal(store.segments.length, 1, 'wciąż jeden segment');
  assert.equal(store.segments[0].text, 'Dzień dobry', 'tekst podmieniony, nie doklejony');
});

test('zamknięcie tury domyka segment ostateczną transkrypcją', async () => {
  const { store, diarizer, adapter } = setup({ texts: ['Dzień', 'Dzień dobry wszystkim, zaczynamy.'] });
  adapter.start();
  diarizer.onTurnStart({ startMs: T0 + 100 });
  feed(adapter, 4);
  await adapter._tickForTest();

  await diarizer.onTurn({ speaker: 0, startMs: T0 + 100, endMs: T0 + 3800 });
  assert.equal(store.segments.length, 1);
  assert.equal(store.segments[0].text, 'Dzień dobry wszystkim, zaczynamy.');
  assert.equal(store.segments[0].final, true);
});

test('wypowiedź bez rozpoznanego tekstu nie zostawia pustego segmentu', async () => {
  const { store, diarizer, adapter } = setup({ texts: [''] });
  adapter.start();
  diarizer.onTurnStart({ startMs: T0 + 100 });
  feed(adapter, 4);
  await adapter._tickForTest();
  await diarizer.onTurn({ speaker: 0, startMs: T0 + 100, endMs: T0 + 3800 });
  assert.equal(store.segments.length, 0);
});

test('za krótkie audio nie idzie do transkrypcji', async () => {
  const { diarizer, adapter, calls } = setup();
  adapter.start();
  diarizer.onTurnStart({ startMs: T0 + 100 });
  feed(adapter, 0.3);
  await adapter._tickForTest();
  assert.equal(calls(), 0, 'poniżej minAudioMs nie ma czego transkrybować');
});

test('błąd serwera jest raportowany, nie wywala adaptera', async () => {
  const { store, diarizer, adapter } = setup();
  adapter.client = {
    transcribe: async () => {
      throw new WhisperLocalError('whisper-server padł', { code: 'offline' });
    },
  };
  adapter.start();
  diarizer.onTurnStart({ startMs: T0 + 100 });
  feed(adapter, 4);
  await adapter._tickForTest();

  assert.match(adapter.status.error, /padł/);
  assert.equal(store.segments.length, 0);
});

test('status raportuje zmierzone opóźnienie', async () => {
  const { diarizer, adapter } = setup();
  adapter.start();
  diarizer.onTurnStart({ startMs: T0 + 100 });
  feed(adapter, 4);
  await adapter._tickForTest();
  assert.equal(adapter.status.backend, 'whisper-local');
  assert.ok(adapter.status.latencyMs >= 0);
});
