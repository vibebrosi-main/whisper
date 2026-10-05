/**
 * Adapter transkrypcji przez Groq Whisper.
 *
 * Różnica względem adaptera Web Speech jest zasadnicza, nie kosmetyczna:
 * tam ASR biegnie ciągle, a mówcę doklejamy zgadując, kto dominował w oknie
 * czasu wyniku. Tutaj to diaryzator wyznacza jednostkę pracy — każda zamknięta
 * tura to jedno żądanie do Groqa. Chunk *z definicji* należy do jednego mówcy,
 * więc przypisanie osoby jest dokładne, a nie przybliżone.
 *
 * Cena: transkrypcja pojawia się dopiero po zakończeniu wypowiedzi.
 */

import { Diarizer } from './diarizer.js';
import { AudioRing } from './ring.js';
import { encodeWav } from './wav.js';
import { GroqTranscriber, TranscriptionQueue } from './groq.js';
import { SOURCE_LABELS } from './index.js';

const DEFAULTS = {
  /** Krótsze tury pomijamy: to zwykle kaszlnięcia, a Groq liczy min. 10 s za żądanie. */
  minUtteranceMs: 600,
  /** Nie wysyłamy monologów bez końca — Groq ma limit rozmiaru pliku. */
  maxUtteranceMs: 120_000,
  /** Margines wokół tury: VAD ucina ciche początki głosek. */
  padMs: 250,
  /** Ile sekund audio trzymamy w oczekiwaniu na zamknięcie tury. */
  ringSeconds: 150,
  sampleRate: 16_000,
};

export class GroqAdapter {
  static id = 'groq';

  #sequence = 0;

  constructor({
    store,
    source = 'tab',
    label,
    apiKey,
    model,
    language = null,
    epochMs = Date.now(),
    diarizer,
    transcriber,
    queue,
    onChange = () => {},
    onError = () => {},
    ...options
  } = {}) {
    if (!store) throw new Error('GroqAdapter wymaga store');
    const config = { ...DEFAULTS, ...options };

    this.store = store;
    this.source = source;
    this.label = label ?? SOURCE_LABELS[source] ?? SOURCE_LABELS.tab;
    this.minUtteranceMs = config.minUtteranceMs;
    this.maxUtteranceMs = config.maxUtteranceMs;
    this.padMs = config.padMs;
    this.epochMs = epochMs;
    this.onChange = onChange;
    this.onError = onError;

    this.ring = new AudioRing({
      sampleRate: config.sampleRate,
      seconds: config.ringSeconds,
      epochMs,
    });

    this.diarizer =
      diarizer ??
      new Diarizer({ ...options, sampleRate: config.sampleRate });
    this.diarizer.onTurn = (turn) => this.#handleTurn(turn);

    this.transcriber = transcriber ?? new GroqTranscriber({ apiKey, model, language });
    this.queue =
      queue ??
      new TranscriptionQueue({
        transcriber: this.transcriber,
        onResult: (result, meta) => this.#handleResult(result, meta),
        onError: (error, meta) => this.#handleError(error, meta),
      });

    this.running = false;
    this.lastError = null;
    this.skipped = 0;
  }

  /** Ramka PCM: trafia i do bufora (na przyszłe cięcie), i do diaryzatora. */
  pushFrame(frame, tMs) {
    if (!this.running) return null;
    // Bufor dostaje tylko nowy fragment ramki — ramki analizy nachodzą na siebie.
    this.ring.write(frame.subarray(frame.length - this.diarizer.extractor.hopSize));
    return this.diarizer.pushFrame(frame, tMs);
  }

  #handleTurn(turn) {
    if (!this.running) return;

    const lengthMs = turn.endMs - turn.startMs;
    if (lengthMs < this.minUtteranceMs) {
      this.skipped++;
      return;
    }

    const startMs = turn.startMs - this.padMs;
    const endMs = Math.min(turn.endMs + this.padMs, turn.startMs + this.maxUtteranceMs);
    const pcm = this.ring.readRange(startMs, endMs);
    if (!pcm?.length) {
      this.skipped++;
      return;
    }

    const meta = {
      key: `groq:${this.source}:${++this.#sequence}`,
      speaker: this.label(turn.speaker),
      startMs: turn.startMs,
      endMs: turn.endMs,
    };

    // Segment pojawia się od razu jako „w toku" — inaczej UI milczałby przez
    // cały czas trwania żądania i wyglądał na zawieszony.
    this.store.upsert({ key: meta.key, speaker: meta.speaker, text: '…', at: turn.startMs, replace: true });
    this.onChange(this.store);

    const accepted = this.queue.enqueue({ wav: encodeWav(pcm, { sampleRate: this.ring.sampleRate }), meta });
    if (!accepted) {
      this.store.seal(meta.key, turn.endMs);
      this.skipped++;
    }
  }

  /** Publiczne wejścia dla wstrzykniętej kolejki (produkcja używa domyślnej). */
  _onResult(result, meta) {
    this.#handleResult(result, meta);
  }

  _onError(error, meta) {
    this.#handleError(error, meta);
  }

  #handleResult(result, meta) {
    this.store.upsert({
      key: meta.key,
      speaker: meta.speaker,
      text: result.text,
      at: meta.startMs,
      replace: true,
    });
    this.store.seal(meta.key, meta.endMs);
    this.lastError = null;
    this.onChange(this.store);
  }

  #handleError(error, meta) {
    this.lastError = error?.message ?? String(error);
    // Placeholder musi zniknąć bez śladu — pusty segment jest gorszy niż brak.
    this.store.discard(meta.key);
    this.store.seal(meta.key, meta.endMs);
    this.onError(error);
    this.onChange(this.store);
  }

  start() {
    this.running = true;
    return this;
  }

  async stop(now = Date.now()) {
    this.running = false;
    this.diarizer.flush(now);
    await this.queue.drain();
    this.store.finalizeAll(now);
    this.onChange(this.store);
    return this;
  }

  get status() {
    return {
      running: this.running,
      source: this.source,
      backend: 'groq',
      speakers: this.diarizer.speakerCount,
      pending: this.queue.pending,
      skipped: this.skipped,
      error: this.lastError,
    };
  }
}
