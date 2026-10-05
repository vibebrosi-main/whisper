/**
 * Rozpoznawanie mówcy po głosie (diaryzacja) — online, bez modelu neuronowego.
 *
 * Łańcuch: ramki PCM -> VAD -> MFCC -> embedding wypowiedzi -> klastrowanie
 * online po podobieństwie kosinusowym. Embedding to statystyki cepstralne
 * (średnia + odchylenie), czyli klasyczne podejście sprzed ery sieci
 * neuronowych.
 *
 * Świadome ograniczenie: to rozdziela wyraźnie różne głosy, ale jest istotnie
 * słabsze od modeli typu x-vector/ECAPA. Podobne głosy potrafi skleić.
 */

import { MfccExtractor } from './features.js';
import { Vad } from './vad.js';

export const DIARIZER_DEFAULTS = {
  /** Powyżej tego podobieństwa kosinusowego to ten sam mówca. */
  threshold: 0.82,
  maxSpeakers: 8,
  /** Ile ramek mowy musi się zebrać, zanim w ogóle zgadujemy mówcę. */
  minFrames: 25,
  /** Co ile ramek odświeżamy prowizoryczną etykietę w trakcie mówienia. */
  refreshEveryFrames: 25,
  /** Inercja centroidu — nowa próbka nie może go przewrócić. */
  centroidInertia: 0.85,
};

/** Kosinus między wektorami znormalizowanymi L2. */
export function cosineSimilarity(a, b) {
  let dot = 0;
  for (let i = 0; i < a.length; i++) dot += a[i] * b[i];
  return dot;
}

/** Normalizacja L2 w miejscu. */
export function l2Normalize(vector) {
  let sum = 0;
  for (let i = 0; i < vector.length; i++) sum += vector[i] * vector[i];
  const norm = Math.sqrt(sum) || 1;
  for (let i = 0; i < vector.length; i++) vector[i] /= norm;
  return vector;
}

/**
 * Embedding wypowiedzi: [średnia MFCC, odchylenie MFCC], znormalizowany L2.
 * @param {Float64Array[]} frames
 * @param {Float64Array|null} cmnMean średnia cepstralna sesji (odejmowana)
 */
export function embedFrames(frames, cmnMean = null) {
  if (!frames.length) return null;
  const dim = frames[0].length;
  const mean = new Float64Array(dim);
  const variance = new Float64Array(dim);

  for (const frame of frames) {
    for (let i = 0; i < dim; i++) mean[i] += frame[i];
  }
  for (let i = 0; i < dim; i++) mean[i] /= frames.length;

  for (const frame of frames) {
    for (let i = 0; i < dim; i++) {
      const d = frame[i] - mean[i];
      variance[i] += d * d;
    }
  }
  for (let i = 0; i < dim; i++) variance[i] = Math.sqrt(variance[i] / frames.length);

  const embedding = new Float64Array(dim * 2);
  for (let i = 0; i < dim; i++) {
    // CMN usuwa wpływ kanału (mikrofon, kodek), zostawiając mówcę.
    embedding[i] = mean[i] - (cmnMean ? cmnMean[i] : 0);
    embedding[dim + i] = variance[i];
  }
  return l2Normalize(embedding);
}

/** Klastrowanie online: przypisuje embedding do mówcy albo zakłada nowego. */
export class SpeakerTracker {
  constructor(options = {}) {
    const config = { ...DIARIZER_DEFAULTS, ...options };
    this.threshold = config.threshold;
    this.maxSpeakers = config.maxSpeakers;
    this.inertia = config.centroidInertia;
    /** @type {{centroid: Float64Array, count: number}[]} */
    this.speakers = [];
  }

  /**
   * @returns {{index: number, similarity: number, isNew: boolean}}
   */
  assign(embedding) {
    let best = -1;
    let bestSimilarity = -Infinity;

    for (let i = 0; i < this.speakers.length; i++) {
      const similarity = cosineSimilarity(embedding, this.speakers[i].centroid);
      if (similarity > bestSimilarity) {
        bestSimilarity = similarity;
        best = i;
      }
    }

    if (best >= 0 && bestSimilarity >= this.threshold) {
      this.#update(best, embedding);
      return { index: best, similarity: bestSimilarity, isNew: false };
    }

    if (this.speakers.length < this.maxSpeakers) {
      this.speakers.push({ centroid: Float64Array.from(embedding), count: 1 });
      return { index: this.speakers.length - 1, similarity: bestSimilarity, isNew: true };
    }

    // Limit mówców wyczerpany — dokładamy do najbliższego zamiast zgadywać.
    this.#update(best, embedding);
    return { index: best, similarity: bestSimilarity, isNew: false };
  }

  #update(index, embedding) {
    const speaker = this.speakers[index];
    const centroid = speaker.centroid;
    for (let i = 0; i < centroid.length; i++) {
      centroid[i] = centroid[i] * this.inertia + embedding[i] * (1 - this.inertia);
    }
    l2Normalize(centroid);
    speaker.count++;
  }

  get count() {
    return this.speakers.length;
  }
}

/**
 * Pełny diaryzator: karmisz go ramkami PCM, oddaje etykiety mówców i tury.
 */
export class Diarizer {
  #frames = [];
  #turnStartMs = 0;
  #framesSinceRefresh = 0;
  #lastFrameMs = 0;

  constructor(options = {}) {
    const config = { ...DIARIZER_DEFAULTS, ...options };
    this.extractor = options.extractor ?? new MfccExtractor(options);
    this.vad = options.vad ?? new Vad(options);
    this.tracker = new SpeakerTracker(config);
    this.minFrames = config.minFrames;
    this.refreshEveryFrames = config.refreshEveryFrames;
    /** Wołane przy zamknięciu tury — backend plikowy (Groq) tnie tu audio. */
    this.onTurn = options.onTurn ?? (() => {});
    /** Wołane przy otwarciu tury — backend strumieniowy zaczyna tu nasłuch. */
    this.onTurnStart = options.onTurnStart ?? (() => {});

    /** Indeks mówcy aktualnie mówiącego, albo null. */
    this.currentSpeaker = null;
    /** @type {{speaker: number, startMs: number, endMs: number}[]} */
    this.turns = [];
  }

  /**
   * Jedna ramka PCM (frameSize próbek).
   * @param {Float32Array|Float64Array} frame
   * @param {number} tMs czas początku ramki
   */
  pushFrame(frame, tMs) {
    const energyDb = MfccExtractor.frameEnergyDb(frame);
    this.#lastFrameMs = tMs;
    const state = this.vad.push(energyDb);

    if (state.started) {
      this.#frames = [];
      this.#framesSinceRefresh = 0;
      this.#turnStartMs = tMs;
      this.currentSpeaker = null;
      this.onTurnStart({ startMs: tMs });
    }

    if (state.speaking && state.loud) {
      this.#frames.push(this.extractor.frameToMfcc(frame));
      this.#framesSinceRefresh++;

      const enough = this.#frames.length >= this.minFrames;
      const due = this.#framesSinceRefresh >= this.refreshEveryFrames;
      if (enough && (this.currentSpeaker === null || due)) {
        this.#framesSinceRefresh = 0;
        this.#classify();
      }
    }

    if (state.ended) this.#closeTurn(tMs);
    return this.currentSpeaker;
  }

  #classify() {
    // Świadomie bez CMN: w obrębie jednego źródła kanał jest stały, więc
    // normalizacja cepstralna nic nie różnicuje, a jej dryf w trakcie sesji
    // przesuwa przestrzeń embeddingów pod już nauczonymi centroidami.
    const embedding = embedFrames(this.#frames);
    if (!embedding) return;
    this.currentSpeaker = this.tracker.assign(embedding).index;
  }

  #closeTurn(endMs) {
    if (this.currentSpeaker !== null && endMs > this.#turnStartMs) {
      const turn = { speaker: this.currentSpeaker, startMs: this.#turnStartMs, endMs };
      this.turns.push(turn);
      this.onTurn(turn);
    }
    this.#frames = [];
    this.currentSpeaker = null;
  }

  /** Domyka otwartą turę — na koniec sesji. */
  flush(endMs) {
    if (this.vad.speaking) {
      if (this.currentSpeaker === null && this.#frames.length) this.#classify();
      this.#closeTurn(endMs);
      this.vad.reset();
    }
  }

  /**
   * Kto dominował w oknie czasu — tak wiążemy tekst z ASR z mówcą.
   * Uwzględnia też turę wciąż otwartą.
   * @returns {number|null}
   */
  dominantSpeaker(fromMs, toMs) {
    const totals = new Map();
    const add = (speaker, ms) => {
      if (ms > 0) totals.set(speaker, (totals.get(speaker) ?? 0) + ms);
    };

    for (const turn of this.turns) {
      add(turn.speaker, Math.min(turn.endMs, toMs) - Math.max(turn.startMs, fromMs));
    }
    if (this.currentSpeaker !== null) {
      // Tura wciąż otwarta — jej koniec to ostatnia widziana ramka, nie zegar ścienny.
      add(this.currentSpeaker, Math.min(toMs, this.#lastFrameMs) - Math.max(this.#turnStartMs, fromMs));
    }

    let best = null;
    let bestMs = 0;
    for (const [speaker, ms] of totals) {
      if (ms > bestMs) {
        bestMs = ms;
        best = speaker;
      }
    }
    return best;
  }

  get speakerCount() {
    return this.tracker.count;
  }
}
