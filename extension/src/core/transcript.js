/**
 * TranscriptStore — rdzeń niezależny od platformy.
 *
 * Adapter (Meet, Zoom, mikrofon…) woła `upsert()` z migawką aktualnie
 * widocznego bloku napisów. Store zajmuje się resztą: scalaniem strumienia,
 * pilnowaniem tożsamości mówcy, finalizacją po ciszy i łączeniem
 * poszatkowanych wypowiedzi tej samej osoby.
 */

import { normalize, reconcile, wordCount } from './text.js';

export const UNKNOWN_SPEAKER = 'Nieznany';

const DEFAULTS = {
  /** Po tylu ms bez zmiany tekstu segment uznajemy za domknięty. */
  silenceMs: 2500,
  /** Kolejny segment tej samej osoby w tym oknie doklejamy do poprzedniego. */
  mergeGapMs: 2500,
  /** Nie sklejamy w nieskończoność — twardy limit długości akapitu. */
  maxMergedMs: 60_000,
  /** Krótsze wypowiedzi niż tyle znaków są ignorowane przy finalizacji. */
  minChars: 1,
};

let idCounter = 0;

/** Ile domkniętych bloków pamiętamy, żeby nie zdublować ich treści. */
const RETIRED_LIMIT = 100;
/** Ile zapieczętowanych kluczy pamiętamy (patrz `seal`). */
const SEALED_LIMIT = 200;

export class TranscriptStore {
  #segments = [];
  #live = new Map(); // key adaptera -> segment
  /**
   * key adaptera -> treść ostatnio domkniętego segmentu.
   *
   * Meet zostawia blok napisów widoczny jeszcze długo po tym, jak ktoś skończy
   * mówić. Bez tej pamięci każdy kolejny odczyt tego samego, niezmienionego
   * bloku tworzyłby nowy segment z tą samą wypowiedzią — w kółko.
   */
  #retired = new Map();
  /**
   * Klucze domknięte ostatecznie — kolejne migawki są ignorowane.
   *
   * Web Speech potrafi ponownie wysłać wynik o indeksie, który już oznaczyliśmy
   * jako final. Bez tej pieczęci powstawał drugi segment z całą wypowiedzią.
   */
  #sealed = new Set();

  constructor(options = {}) {
    const opts = { ...DEFAULTS, ...options };
    this.startedAt = opts.startedAt ?? Date.now();
    this.silenceMs = opts.silenceMs;
    this.mergeGapMs = opts.mergeGapMs;
    this.maxMergedMs = opts.maxMergedMs;
    this.minChars = opts.minChars;
    /** Rośnie przy każdej zmianie — tanie źródło prawdy dla UI. */
    this.revision = 0;
  }

  /**
   * Migawka aktualnego bloku napisów.
   * @param {{key: string, speaker?: string|null, text: string, at?: number}} input
   * @returns {object|null} segment, do którego trafił tekst
   */
  /**
   * Migawka aktualnego bloku napisów.
   *
   * `replace: true` oznacza, że źródło podaje pełną, poprawioną treść przy
   * każdej aktualizacji (tak działa Web Speech) — wtedy tekst podmieniamy
   * zamiast scalać. Domyślne `false` jest dla źródeł, które tekst dopisują
   * i przewijają (napisy Meet).
   */
  upsert({ key, speaker, text, at = Date.now(), replace = false }) {
    const body = normalize(text);
    if (!body) return null;
    if (this.#sealed.has(key)) return null;
    const who = normalize(speaker) || UNKNOWN_SPEAKER;

    let seg = this.#live.get(key);

    // Ten sam blok DOM przejęty przez innego mówcę => zamykamy poprzedni.
    if (seg && seg.speaker !== who) {
      this.#close(seg, at);
      this.#live.delete(key);
      seg = null;
    }

    let text_ = body;
    if (!seg) {
      const retired = this.#retired.get(key);
      if (retired && retired.speaker === who) {
        // Przy pełnych migawkach domknięte znaczy domknięte — poprawka
        // wyniku, który już zamknęliśmy, nie ma czego dopisać.
        if (replace) return null;
        const merged = reconcile(retired.text, body);
        if (merged === retired.text) return null; // blok wisi, nic nowego nie padło
        // Nowy segment dostaje wyłącznie to, czego jeszcze nie zapisaliśmy.
        text_ = merged.startsWith(retired.text) ? normalize(merged.slice(retired.text.length)) : merged;
        this.#retired.delete(key);
        if (!text_) return null;
      }
    }

    if (!seg) {
      seg = {
        id: `s${++idCounter}`,
        key,
        speaker: who,
        text: text_,
        startedAt: at,
        updatedAt: at,
        final: false,
      };
      this.#segments.push(seg);
      this.#live.set(key, seg);
      this.revision++;
      return seg;
    }

    const merged = replace ? body : reconcile(seg.text, body);
    if (merged !== seg.text) {
      seg.text = merged;
      seg.updatedAt = at; // updatedAt rośnie tylko przy realnej zmianie -> działa detekcja ciszy
      this.revision++;
    }
    return seg;
  }

  /** Domyka segmenty, które od `silenceMs` nic nie zmieniły. */
  finalizeIdle(now = Date.now()) {
    for (const [key, seg] of [...this.#live]) {
      if (now - seg.updatedAt >= this.silenceMs) {
        this.#close(seg, now);
        this.#live.delete(key);
      }
    }
  }

  /** Blok zniknął z DOM — wypowiedź na pewno się skończyła. */
  dropKey(key, now = Date.now()) {
    const seg = this.#live.get(key);
    if (seg) {
      this.#close(seg, now);
      this.#live.delete(key);
    }
    this.#retired.delete(key);
  }

  /**
   * Domyka segment i zamyka klucz na dobre.
   *
   * Różnica względem `dropKey`: tam blok zniknął z DOM i klucz nigdy nie wróci,
   * więc pamięć można skasować. Tutaj źródło może ten sam klucz wysłać
   * ponownie i właśnie przed tym się bronimy.
   */
  seal(key, now = Date.now()) {
    const seg = this.#live.get(key);
    if (seg) {
      this.#close(seg, now);
      this.#live.delete(key);
    }
    this.#retired.delete(key);
    this.#sealed.add(key);
    if (this.#sealed.size > SEALED_LIMIT) {
      this.#sealed.delete(this.#sealed.values().next().value);
    }
  }

  #retire(seg) {
    if (seg.key == null) return;
    this.#retired.set(seg.key, { speaker: seg.speaker, text: seg.text });
    if (this.#retired.size > RETIRED_LIMIT) {
      this.#retired.delete(this.#retired.keys().next().value);
    }
  }

  /**
   * Usuwa segment bez śladu.
   *
   * `dropKey` tylko domyka wypowiedź — tutaj chodzi o wycofanie czegoś, co
   * nigdy nie powinno trafić do transkryptu, np. znacznika „w toku" po
   * nieudanej transkrypcji.
   */
  discard(key) {
    const seg = this.#live.get(key);
    if (!seg) return false;
    const index = this.#segments.indexOf(seg);
    if (index >= 0) this.#segments.splice(index, 1);
    this.#live.delete(key);
    this.#retired.delete(key);
    this.revision++;
    return true;
  }

  /** Koniec sesji. */
  finalizeAll(now = Date.now()) {
    for (const seg of [...this.#live.values()]) this.#close(seg, now);
    this.#live.clear();
  }

  #close(seg, now) {
    seg.final = true;
    seg.endedAt = Math.max(seg.updatedAt, seg.startedAt);
    this.#retire(seg);

    if (normalize(seg.text).length < this.minChars) {
      const i = this.#segments.indexOf(seg);
      if (i >= 0) this.#segments.splice(i, 1);
      this.revision++;
      return;
    }

    // Sklejanie poszatkowanych wypowiedzi tej samej osoby.
    const i = this.#segments.indexOf(seg);
    const prev = i > 0 ? this.#segments[i - 1] : null;
    if (
      prev &&
      prev.final &&
      prev.speaker === seg.speaker &&
      seg.startedAt - (prev.endedAt ?? prev.updatedAt) <= this.mergeGapMs &&
      seg.updatedAt - prev.startedAt <= this.maxMergedMs
    ) {
      prev.text = reconcile(prev.text, seg.text);
      prev.updatedAt = seg.updatedAt;
      prev.endedAt = seg.endedAt;
      this.#segments.splice(i, 1);
    }
    this.revision++;
  }

  /** Wszystkie segmenty (domknięte i na żywo) z policzonym offsetem. */
  get segments() {
    return this.#segments.map((s) => ({
      id: s.id,
      speaker: s.speaker,
      text: s.text,
      startedAt: s.startedAt,
      endedAt: s.endedAt ?? s.updatedAt,
      offsetMs: Math.max(0, s.startedAt - this.startedAt),
      final: s.final,
    }));
  }

  get liveCount() {
    return this.#live.size;
  }

  get isEmpty() {
    return this.#segments.length === 0;
  }

  /** Statystyki per osoba, w kolejności pierwszego wystąpienia. */
  get speakers() {
    const map = new Map();
    for (const s of this.#segments) {
      let row = map.get(s.speaker);
      if (!row) {
        row = { name: s.speaker, segments: 0, chars: 0, words: 0, firstAt: s.startedAt, talkMs: 0 };
        map.set(s.speaker, row);
      }
      row.segments++;
      row.chars += s.text.length;
      row.words += wordCount(s.text);
      row.talkMs += Math.max(0, (s.endedAt ?? s.updatedAt) - s.startedAt);
    }
    return [...map.values()];
  }

  toJSON() {
    return { startedAt: this.startedAt, segments: this.segments };
  }

  static fromJSON(data, options = {}) {
    const store = new TranscriptStore({ ...options, startedAt: data?.startedAt ?? Date.now() });
    for (const s of data?.segments ?? []) {
      store.#segments.push({
        id: s.id ?? `s${++idCounter}`,
        key: null,
        speaker: s.speaker || UNKNOWN_SPEAKER,
        text: s.text || '',
        startedAt: s.startedAt ?? store.startedAt,
        updatedAt: s.endedAt ?? s.startedAt ?? store.startedAt,
        endedAt: s.endedAt ?? s.startedAt ?? store.startedAt,
        final: true,
      });
    }
    return store;
  }
}
