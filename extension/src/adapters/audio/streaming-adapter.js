/**
 * Transkrypcja przyrostowa — tekst pojawia się W TRAKCIE mówienia.
 *
 * Adapter Groqa czeka, aż VAD domknie turę, więc przy dwudziestosekundowej
 * wypowiedzi tekst pojawia się po dwudziestu sekundach. To jest dominująca
 * latencja całego narzędzia — większa niż jakakolwiek inferencja.
 *
 * Tutaj co `intervalMs` transkrybujemy wypowiedź OD JEJ POCZĄTKU do teraz
 * i podmieniamy tekst segmentu. Wygląda to na marnotrawstwo, ale nie jest:
 * encoder Whispera kosztuje tyle samo niezależnie od długości audio (wejście
 * jest zawsze dopychane do 30 s), a na M4 z modelem `small` to ~190 ms.
 *
 * Efekt: pierwszy tekst ~1,5 s po rozpoczęciu mówienia, potem aktualizacje
 * na bieżąco — zamiast ciszy przez całą wypowiedź.
 */

import { Diarizer } from './diarizer.js';
import { AudioRing } from './ring.js';
import { WhisperLocalClient } from './whisper-local.js';
import { SOURCE_LABELS } from './index.js';

const DEFAULTS = {
  /** Co ile odświeżamy transkrypcję trwającej wypowiedzi. */
  intervalMs: 1200,
  /** Zanim to minie, nie ma czego transkrybować. */
  minAudioMs: 700,
  /** Twardy limit jednej wypowiedzi — dłuższe tniemy, żeby nie rosło bez końca. */
  maxUtteranceMs: 45_000,
  /** Margines przed początkiem tury: VAD ucina ciche początki głosek. */
  padMs: 200,
  ringSeconds: 90,
  sampleRate: 16_000,
};

export class StreamingWhisperAdapter {
  static id = 'whisper-local';

  #sequence = 0;
  #timer = null;
  #inFlight = null;
  #utterance = null;

  constructor({
    store,
    source = 'tab',
    label,
    client,
    diarizer,
    epochMs = Date.now(),
    onChange = () => {},
    onError = () => {},
    ...options
  } = {}) {
    if (!store) throw new Error('StreamingWhisperAdapter wymaga store');
    const config = { ...DEFAULTS, ...options };

    this.store = store;
    this.source = source;
    this.label = label ?? SOURCE_LABELS[source] ?? SOURCE_LABELS.tab;
    this.intervalMs = config.intervalMs;
    this.minAudioMs = config.minAudioMs;
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

    this.diarizer = diarizer ?? new Diarizer({ ...options, sampleRate: config.sampleRate });
    this.diarizer.onTurnStart = (turn) => this.#openUtterance(turn);
    this.diarizer.onTurn = (turn) => this.#closeUtterance(turn);

    this.client = client ?? new WhisperLocalClient(options);
    this.running = false;
    this.lastError = null;
    this.lastLatencyMs = null;
  }

  pushFrame(frame, tMs) {
    if (!this.running) return null;
    // Do bufora trafia tylko nowa część ramki — ramki analizy nachodzą na siebie.
    this.ring.write(frame.subarray(frame.length - this.diarizer.extractor.hopSize));
    return this.diarizer.pushFrame(frame, tMs);
  }

  #openUtterance({ startMs }) {
    this.#utterance = {
      key: `whisper:${this.source}:${++this.#sequence}`,
      startMs,
      speaker: null,
      lastText: '',
    };
  }

  /** Etykieta mówcy bywa znana dopiero po kilkuset ms mowy. */
  #speakerFor(utterance) {
    if (utterance.speaker) return utterance.speaker;
    const index = this.diarizer.currentSpeaker;
    if (index === null || index === undefined) return null;
    utterance.speaker = this.label(index);
    return utterance.speaker;
  }

  /** Wejście dla testów — produkcja tickuje z interwału. */
  _tickForTest() {
    return this.#tick();
  }

  async #tick() {
    const utterance = this.#utterance;
    if (!utterance || this.#inFlight) return;

    const now = this.ring.newestMs;
    const elapsed = now - utterance.startMs;
    if (elapsed < this.minAudioMs) return;

    const from = utterance.startMs - this.padMs;
    const to = Math.min(now, utterance.startMs + this.maxUtteranceMs);
    const pcm = this.ring.readRange(from, to);
    if (!pcm?.length) return;

    this.#inFlight = this.#transcribe(utterance, pcm, { final: false });
    try {
      await this.#inFlight;
    } finally {
      this.#inFlight = null;
    }
  }

  async #transcribe(utterance, pcm, { final }) {
    const startedAt = Date.now();
    try {
      const { text } = await this.client.transcribe(pcm, { sampleRate: this.ring.sampleRate });
      this.lastLatencyMs = Date.now() - startedAt;
      this.lastError = null;

      if (!text || text === utterance.lastText) return;
      utterance.lastText = text;

      this.store.upsert({
        key: utterance.key,
        speaker: this.#speakerFor(utterance) ?? 'Nieznany',
        text,
        at: utterance.startMs,
        // Każda runda to pełna transkrypcja tego samego audio, nie ogon.
        replace: true,
      });
      if (final) this.store.seal(utterance.key, Date.now());
      this.onChange(this.store);
    } catch (error) {
      if (error?.name === 'AbortError') return;
      this.lastError = error?.message ?? String(error);
      this.onError(error);
    }
  }

  async #closeUtterance(turn) {
    const utterance = this.#utterance;
    this.#utterance = null;
    if (!utterance) return;

    // Etykieta mówcy z domkniętej tury jest pewniejsza niż ta prowizoryczna.
    utterance.speaker = this.label(turn.speaker);

    await this.#inFlight?.catch(() => {});
    const pcm = this.ring.readRange(
      utterance.startMs - this.padMs,
      Math.min(turn.endMs + this.padMs, utterance.startMs + this.maxUtteranceMs),
    );

    if (!pcm?.length) {
      if (!utterance.lastText) this.store.discard(utterance.key);
      this.store.seal(utterance.key, turn.endMs);
      this.onChange(this.store);
      return;
    }
    await this.#transcribe(utterance, pcm, { final: true });
    this.store.seal(utterance.key, turn.endMs);
    this.onChange(this.store);
  }

  start() {
    if (this.running) return this;
    this.running = true;
    this.#timer = setInterval(() => {
      this.#tick().catch((error) => this.onError(error));
    }, this.intervalMs);
    // W node timer trzymałby pętlę zdarzeń otwartą; w przeglądarce to no-op.
    this.#timer?.unref?.();
    return this;
  }

  async stop(now = Date.now()) {
    this.running = false;
    clearInterval(this.#timer);
    this.#timer = null;
    this.diarizer.flush(now);
    await this.#inFlight?.catch(() => {});
    this.#utterance = null;
    this.store.finalizeAll(now);
    this.onChange(this.store);
    return this;
  }

  get status() {
    return {
      running: this.running,
      source: this.source,
      backend: 'whisper-local',
      speakers: this.diarizer.speakerCount,
      latencyMs: this.lastLatencyMs,
      error: this.lastError,
    };
  }
}
