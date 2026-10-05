import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderMarkdown } from '../extension/src/core/markdown.js';
import { Session, slugify } from '../extension/src/core/session.js';

const START = Date.parse('2026-08-23T10:15:03');

function sampleSession() {
  const session = new Session({
    title: 'Standup zespołu',
    source: 'google-meet',
    url: 'https://meet.google.com/abc-defg-hij',
    startedAt: START,
  });
  session.store.upsert({ key: 'a', speaker: 'Anna Kowalska', text: 'Cześć wszystkim, zaczynamy.', at: START + 4000 });
  session.store.dropKey('a', START + 6000);
  session.store.upsert({ key: 'b', speaker: 'Jan Nowak', text: 'Hej, słychać mnie?', at: START + 11000 });
  session.store.dropKey('b', START + 13000);
  session.end(START + 2_531_000);
  return session;
}

test('markdown ma frontmatter, nagłówek, tabelę i wpisy z timestampami', () => {
  const md = sampleSession().toMarkdown();
  assert.match(md, /^---\n/);
  assert.match(md, /title: "Standup zespołu"/);
  assert.match(md, /source: google-meet/);
  assert.match(md, /duration: "00:42:11"/);
  assert.match(md, /speakers: \["Anna Kowalska", "Jan Nowak"\]/);
  assert.match(md, /^# Standup zespołu$/m);
  assert.match(md, /## Uczestnicy/);
  assert.match(md, /\| Anna Kowalska \| 1 \| 3 \| 50% \|/);
  assert.match(md, /## Transkrypt/);
  assert.match(md, /\*\*\[00:00:04\] Anna Kowalska\*\*/);
  assert.match(md, /\*\*\[00:00:11\] Jan Nowak\*\*/);
  assert.ok(md.endsWith('\n'));
});

test('opcje wyłączają frontmatter i statystyki', () => {
  const md = sampleSession().toMarkdown({ frontmatter: false, stats: false });
  assert.ok(!md.startsWith('---'));
  assert.ok(!md.includes('## Uczestnicy'));
  assert.match(md, /## Transkrypt/);
});

test('absoluteTimestamps zamienia offset na godzinę zegarową', () => {
  const md = sampleSession().toMarkdown({ absoluteTimestamps: true });
  assert.match(md, /\*\*\[10:15:07\] Anna Kowalska\*\*/);
  assert.ok(!md.includes('[00:00:04]'));
});

test('locale en przełącza nagłówki', () => {
  const md = sampleSession().toMarkdown({ locale: 'en' });
  assert.match(md, /## Participants/);
  assert.match(md, /## Transcript/);
  assert.match(md, /\| Person \| Utterances \| Words \| Share \|/);
});

test('znaki markdownowe w wypowiedzi są escapowane', () => {
  const session = new Session({ title: 'Test', startedAt: START });
  session.store.upsert({ key: 'a', speaker: 'Ala', text: 'użyj *gwiazdki* i _podkreślenia_', at: START });
  session.end(START + 1000);
  assert.match(session.toMarkdown(), /użyj \\\*gwiazdki\\\* i \\_podkreślenia\\_/);
});

test('pusta sesja renderuje się z komunikatem zamiast krzaczyć', () => {
  const md = renderMarkdown({ meta: { title: 'Pusto', startedAt: START, endedAt: START }, segments: [] });
  assert.match(md, /# Pusto/);
  assert.match(md, /Brak transkrypcji/);
});

test('segment na żywo jest oznaczony', () => {
  const session = new Session({ title: 'Live', startedAt: START });
  session.store.upsert({ key: 'a', speaker: 'Ala', text: 'mówię właśnie', at: START + 500 });
  assert.match(session.toMarkdown(), /_\(w trakcie\)_/);
});

test('roundtrip sesji przez JSON daje identyczny markdown', () => {
  const original = sampleSession();
  const restored = Session.fromJSON(JSON.parse(JSON.stringify(original.toJSON())));
  assert.equal(restored.toMarkdown(), original.toMarkdown());
});

test('nazwa pliku jest bezpieczna i czytelna', () => {
  assert.equal(sampleSession().filename(), '2026-08-23_1015_standup-zespolu.md');
  assert.equal(slugify('Spotkanie Zarządu — Q3/2026'), 'spotkanie-zarzadu-q3-2026');
  assert.equal(slugify(''), 'rozmowa');
});
