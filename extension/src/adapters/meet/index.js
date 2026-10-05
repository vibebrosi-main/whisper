/**
 * Adapter Google Meet.
 *
 * Kontrakt adaptera (ten sam dla przyszłych: Zoom, Teams, mikrofon):
 *   start() / stop() / status  — sterowanie
 *   onChange(store)            — wołane po każdej zmianie transkryptu
 *   Adapter NIE renderuje i NIE zapisuje — wypycha migawki do TranscriptStore.
 *
 * Strategia wydajnościowa: tani `setInterval` szuka kontenera napisów
 * (jedno querySelector na sekundę), a dopiero po jego znalezieniu podpinamy
 * wąski MutationObserver na sam kontener. Nigdy nie obserwujemy całego body —
 * Meet generuje tysiące mutacji na minutę.
 */

import {
  collectBlocks,
  containsNode,
  findCaptionRoot,
  findCaptionsButton,
  captionsState,
  meetingTitle,
  meetingCode,
  parseBlock,
} from './dom.js';

const DEFAULTS = {
  /** Jak często szukamy kontenera napisów / domykamy segmenty po ciszy. */
  pollMs: 1000,
  /** Zwłoka po mutacji — zbija serie zmian w jeden odczyt. */
  debounceMs: 150,
};

export class MeetAdapter {
  static id = 'google-meet';

  #doc;
  #store;
  #onChange;
  #pollMs;
  #debounceMs;

  #root = null;
  #observer = null;
  #pollTimer = null;
  #debounceTimer = null;
  #keys = new WeakMap();
  #liveBlocks = new Map(); // key -> element
  #keySeq = 0;
  #lastSpeaker = null;
  #lastRevision = -1;

  constructor({ doc = document, store, onChange = () => {}, ...options } = {}) {
    if (!store) throw new Error('MeetAdapter wymaga store');
    const opts = { ...DEFAULTS, ...options };
    this.#doc = doc;
    this.#store = store;
    this.#onChange = onChange;
    this.#pollMs = opts.pollMs;
    this.#debounceMs = opts.debounceMs;
    this.running = false;
  }

  get store() {
    return this.#store;
  }

  /** Diagnostyka dla UI. */
  get status() {
    return {
      running: this.running,
      captions: captionsState(this.#doc),
      captionRoot: Boolean(this.#root?.isConnected),
      title: meetingTitle(this.#doc, this.#doc?.location?.href),
      code: meetingCode(this.#doc?.location?.href),
    };
  }

  start() {
    if (this.running) return this;
    this.running = true;
    this.#pollTimer = setInterval(() => this.tick(), this.#pollMs);
    this.tick();
    return this;
  }

  stop() {
    this.running = false;
    clearInterval(this.#pollTimer);
    clearTimeout(this.#debounceTimer);
    this.#pollTimer = null;
    this.#debounceTimer = null;
    this.#detachObserver();
    this.#store.finalizeAll(Date.now());
    this.#emit(true);
    return this;
  }

  #detachObserver() {
    this.#observer?.disconnect();
    this.#observer = null;
    this.#root = null;
  }

  #ensureRoot() {
    // Root przeliczamy co tick (jedno querySelectorAll), ale obserwator
    // przepinamy tylko wtedy, gdy kontener faktycznie się zmienił.
    const root = findCaptionRoot(this.#doc);
    if (root && root === this.#root && this.#root.isConnected !== false) return this.#root;

    this.#detachObserver();
    if (!root) return null;

    this.#root = root;
    const Observer = this.#doc?.defaultView?.MutationObserver ?? globalThis.MutationObserver;
    if (Observer) {
      this.#observer = new Observer(() => this.#scheduleRead());
      this.#observer.observe(root, { childList: true, subtree: true, characterData: true });
    }
    return root;
  }

  #scheduleRead() {
    if (!this.running || this.#debounceTimer) return;
    this.#debounceTimer = setTimeout(() => {
      this.#debounceTimer = null;
      this.#read(Date.now());
      this.#emit();
    }, this.#debounceMs);
  }

  /**
   * Pełny cykl: znajdź kontener, odczytaj, domknij po ciszy, powiadom.
   * Wołany z interwału, ale bezpieczny do wywołania ręcznie (testy, debug).
   */
  tick(now = Date.now()) {
    this.#ensureRoot();
    this.#read(now);
    this.#store.finalizeIdle(now);
    this.#emit();
  }

  #read(now) {
    const root = this.#root?.isConnected ? this.#root : null;
    if (!root) {
      // Napisy zniknęły (wyłączone / koniec rozmowy) — domykamy to, co wisiało.
      for (const key of this.#liveBlocks.keys()) this.#store.dropKey(key, now);
      this.#liveBlocks.clear();
      return;
    }

    for (const el of collectBlocks(root)) {
      const parsed = parseBlock(el);
      if (!parsed) continue;

      const key = this.#keyFor(el);
      this.#liveBlocks.set(key, el);

      const speaker = parsed.speaker ?? this.#lastSpeaker;
      if (parsed.speaker) this.#lastSpeaker = parsed.speaker;

      this.#store.upsert({ key, speaker, text: parsed.text, at: now });
    }

    // Blok zniknął z DOM => wypowiedź na pewno zamknięta. Sprawdzamy obecność
    // w drzewie, a nie wynik parsowania — chwilowo pusty blok to nie koniec zdania.
    for (const [key, el] of [...this.#liveBlocks]) {
      if (el?.isConnected !== false && containsNode(root, el)) continue;
      this.#store.dropKey(key, now);
      this.#liveBlocks.delete(key);
    }
  }

  #keyFor(el) {
    let key = this.#keys.get(el);
    if (!key) {
      key = `meet:${++this.#keySeq}`;
      this.#keys.set(el, key);
    }
    return key;
  }

  #emit(force = false) {
    if (!force && this.#store.revision === this.#lastRevision) return;
    this.#lastRevision = this.#store.revision;
    this.#onChange(this.#store);
  }

  /** Klika przycisk napisów, jeśli są wyłączone. Zwraca true, gdy kliknięto. */
  enableCaptions() {
    if (captionsState(this.#doc) === 'on') return false;
    const button = findCaptionsButton(this.#doc);
    if (!button?.click) return false;
    button.click();
    return true;
  }
}

export { captionsState, findCaptionsButton, meetingTitle, meetingCode };
