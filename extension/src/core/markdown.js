/**
 * Renderer Markdown. Wejście: obiekt sesji (patrz session.js).
 * Wyjście: gotowy dokument z timestampami per osoba.
 */

import { formatOffset, formatDuration, formatLocalDate, formatLocalDateTime, formatLocalTime } from './time.js';
import { normalize } from './text.js';

export const LOCALES = {
  pl: {
    transcript: 'Transkrypt',
    participants: 'Uczestnicy',
    person: 'Osoba',
    utterances: 'Wypowiedzi',
    words: 'Słowa',
    share: 'Udział',
    duration: 'Czas trwania',
    started: 'Start',
    source: 'Źródło',
    untitled: 'Rozmowa',
    empty: '_Brak transkrypcji — napisy nie były włączone albo nikt nie mówił._',
    live: 'w trakcie',
  },
  en: {
    transcript: 'Transcript',
    participants: 'Participants',
    person: 'Person',
    utterances: 'Utterances',
    words: 'Words',
    share: 'Share',
    duration: 'Duration',
    started: 'Started',
    source: 'Source',
    untitled: 'Call',
    empty: '_No transcript — captions were off or nobody spoke._',
    live: 'live',
  },
};

const SOURCE_LABELS = {
  'google-meet': 'Google Meet',
};

function escapeInline(text) {
  // Chronimy tylko to, co realnie psuje render w środku akapitu.
  return normalize(text).replace(/([*_`])/g, '\\$1');
}

function yamlString(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

/**
 * @param {object} session { meta, segments }
 * @param {object} [options] { locale, frontmatter, absoluteTimestamps, stats, escape }
 */
export function renderMarkdown(session, options = {}) {
  const {
    locale = 'pl',
    frontmatter = true,
    absoluteTimestamps = false,
    stats = true,
    escape = true,
  } = options;

  const t = LOCALES[locale] ?? LOCALES.pl;
  const meta = session?.meta ?? {};
  const segments = [...(session?.segments ?? [])].sort((a, b) => a.startedAt - b.startedAt);

  const startedAt = meta.startedAt ?? segments[0]?.startedAt ?? Date.now();
  const endedAt = meta.endedAt ?? segments.at(-1)?.endedAt ?? startedAt;
  const durationMs = Math.max(0, endedAt - startedAt);
  const title = normalize(meta.title) || t.untitled;
  const sourceLabel = SOURCE_LABELS[meta.source] ?? meta.source ?? '';

  const speakers = [];
  const seen = new Map();
  for (const s of segments) {
    let row = seen.get(s.speaker);
    if (!row) {
      row = { name: s.speaker, utterances: 0, words: 0 };
      seen.set(s.speaker, row);
      speakers.push(row);
    }
    row.utterances++;
    row.words += normalize(s.text) ? normalize(s.text).split(' ').length : 0;
  }
  const totalWords = speakers.reduce((acc, s) => acc + s.words, 0) || 1;

  const out = [];

  if (frontmatter) {
    out.push('---');
    out.push(`title: ${yamlString(title)}`);
    if (meta.source) out.push(`source: ${meta.source}`);
    if (meta.url) out.push(`url: ${yamlString(meta.url)}`);
    out.push(`date: ${formatLocalDate(startedAt)}`);
    out.push(`started: ${yamlString(formatLocalDateTime(startedAt))}`);
    out.push(`duration: ${yamlString(formatOffset(durationMs))}`);
    out.push(`speakers: [${speakers.map((s) => yamlString(s.name)).join(', ')}]`);
    out.push('generator: call-whisper');
    out.push('---');
    out.push('');
  }

  out.push(`# ${title}`);
  out.push('');

  const headerBits = [formatLocalDateTime(startedAt, false)];
  if (durationMs > 0) headerBits.push(formatDuration(durationMs));
  if (sourceLabel) headerBits.push(sourceLabel);
  out.push(headerBits.join(' · '));
  out.push('');

  if (stats && speakers.length) {
    out.push(`## ${t.participants}`);
    out.push('');
    out.push(`| ${t.person} | ${t.utterances} | ${t.words} | ${t.share} |`);
    out.push('| --- | ---: | ---: | ---: |');
    for (const s of speakers) {
      const share = Math.round((s.words / totalWords) * 100);
      out.push(`| ${s.name} | ${s.utterances} | ${s.words} | ${share}% |`);
    }
    out.push('');
  }

  out.push(`## ${t.transcript}`);
  out.push('');

  if (!segments.length) {
    out.push(t.empty);
    out.push('');
  }

  for (const s of segments) {
    const stamp = absoluteTimestamps
      ? formatLocalTime(s.startedAt)
      : formatOffset(s.offsetMs ?? s.startedAt - startedAt);
    const suffix = s.final === false ? ` _(${t.live})_` : '';
    out.push(`**[${stamp}] ${s.speaker}**${suffix}`);
    out.push('');
    out.push(escape ? escapeInline(s.text) : normalize(s.text));
    out.push('');
  }

  return `${out.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd()}\n`;
}

/** Krótki podgląd tekstowy (popup, powiadomienia). */
export function renderPreview(segments, limit = 6) {
  return [...segments]
    .slice(-limit)
    .map((s) => `[${formatOffset(s.offsetMs ?? 0)}] ${s.speaker}: ${s.text}`)
    .join('\n');
}
