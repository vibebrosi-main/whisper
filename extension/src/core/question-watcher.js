/**
 * Wyławia pytania z napływających segmentów transkryptu.
 *
 * Sprawdza wyłącznie segmenty domknięte: wypowiedź w trakcie jeszcze się
 * zmienia, a zadanie pytania Claude'owi w połowie zdania kosztuje czas i daje
 * odpowiedź na coś, co nie padło.
 */

import { detectQuestion } from './assistant.js';

export class QuestionWatcher {
  #seen = new Set();

  /**
   * @param {{minConfidence?: number, onQuestion: (item: object) => void, maxSeen?: number}} options
   */
  constructor({ minConfidence = 0.35, onQuestion, maxSeen = 500 } = {}) {
    this.minConfidence = minConfidence;
    this.onQuestion = onQuestion ?? (() => {});
    this.maxSeen = maxSeen;
  }

  /** @param {Array<{id: string, speaker: string, text: string, final: boolean, startedAt: number}>} segments */
  scan(segments) {
    const found = [];
    for (const segment of segments) {
      if (!segment.final || this.#seen.has(segment.id)) continue;
      this.#seen.add(segment.id);

      const verdict = detectQuestion(segment.text);
      if (!verdict.isQuestion || verdict.confidence < this.minConfidence) continue;

      const item = {
        segmentId: segment.id,
        // Właściwe pytanie, bez dygresji przed nim — mniej tokenów, szybsza odpowiedź.
        question: verdict.question || segment.text,
        utterance: segment.text,
        speaker: segment.speaker,
        at: segment.startedAt,
        confidence: verdict.confidence,
        reason: verdict.reason,
      };
      found.push(item);
      this.onQuestion(item);
    }
    this.#trim();
    return found;
  }

  #trim() {
    if (this.#seen.size <= this.maxSeen) return;
    const excess = this.#seen.size - this.maxSeen;
    let removed = 0;
    for (const id of this.#seen) {
      this.#seen.delete(id);
      if (++removed >= excess) break;
    }
  }

  reset() {
    this.#seen.clear();
  }
}
