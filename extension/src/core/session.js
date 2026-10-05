/**
 * Sesja = metadane rozmowy + store transkryptu.
 * Serializowalna do JSON (chrome.storage, plik, backup).
 */

import { TranscriptStore } from './transcript.js';
import { renderMarkdown } from './markdown.js';
import { filenameStamp } from './time.js';
import { normalize } from './text.js';

const SLUG_MAX = 48;

export function slugify(input, fallback = 'rozmowa') {
  const base = normalize(input)
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/ł/g, 'l')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, SLUG_MAX)
    .replace(/-+$/g, '');
  return base || fallback;
}

export class Session {
  /**
   * @param {{id?: string, title?: string, source?: string, url?: string, startedAt?: number}} meta
   * @param {object} [storeOptions]
   */
  constructor(meta = {}, storeOptions = {}) {
    const startedAt = meta.startedAt ?? Date.now();
    this.meta = {
      id: meta.id ?? `cw_${startedAt.toString(36)}_${Math.random().toString(36).slice(2, 7)}`,
      title: meta.title ?? '',
      source: meta.source ?? 'unknown',
      url: meta.url ?? '',
      startedAt,
      endedAt: meta.endedAt ?? null,
    };
    this.store = new TranscriptStore({ ...storeOptions, startedAt });
  }

  get segments() {
    return this.store.segments;
  }

  get revision() {
    return this.store.revision;
  }

  end(now = Date.now()) {
    this.store.finalizeAll(now);
    this.meta.endedAt = now;
    return this;
  }

  toJSON() {
    const segments = this.store.segments;
    return {
      version: 1,
      meta: { ...this.meta, endedAt: this.meta.endedAt ?? segments.at(-1)?.endedAt ?? this.meta.startedAt },
      segments,
    };
  }

  static fromJSON(data, storeOptions = {}) {
    const session = new Session(data?.meta ?? {}, storeOptions);
    session.store = TranscriptStore.fromJSON(
      { startedAt: data?.meta?.startedAt, segments: data?.segments ?? [] },
      storeOptions,
    );
    return session;
  }

  toMarkdown(options = {}) {
    return renderMarkdown(this.toJSON(), options);
  }

  /** np. 2026-08-23_1015_standup-zespolu.md */
  filename(ext = 'md') {
    const stamp = filenameStamp(this.meta.startedAt);
    return `${stamp}_${slugify(this.meta.title || this.meta.source)}.${ext}`;
  }
}
