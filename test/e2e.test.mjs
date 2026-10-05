import { test } from 'node:test';
import assert from 'node:assert/strict';
import { h, t, makeDocument } from './fake-dom.mjs';
import { MeetAdapter } from '../extension/src/adapters/meet/index.js';
import { Session } from '../extension/src/core/session.js';

const START = Date.parse('2026-08-23T10:15:00');

/**
 * Pełna droga: strumień napisów Meeta -> TranscriptStore -> Markdown.
 * Skrypt odwzorowuje realne zachowanie Meeta: tekst dopisywany klatka po klatce,
 * przewijane okno, recykling węzłów DOM i wypadanie starych bloków.
 */
const SCRIPT = [
  [1000, 'Anna Kowalska', 'Dobra'],
  [1600, 'Anna Kowalska', 'Dobra, zaczynamy'],
  [2300, 'Anna Kowalska', 'Dobra, zaczynamy dzisiejszy standup'],
  [3100, 'Anna Kowalska', 'Dobra, zaczynamy dzisiejszy standup. Jan, lecisz pierwszy?'],
  [9000, 'Jan Nowak', 'Jasne'],
  [9800, 'Jan Nowak', 'Jasne, wczoraj domknąłem migrację'],
  [10600, 'Jan Nowak', 'wczoraj domknąłem migrację bazy i dzisiaj biorę raporty'],
  [20000, 'Marta Zielińska', 'Ja czekam na dostęp do stagingu.'],
];

function liveBlock(name) {
  const textLeaf = t('span', '');
  const nameLeaf = t('div', name, { class: 'zs7s8d' });
  const block = h('div', { jsname: 'dsyhDe' }, [
    h('div', { class: 'KcIKyf' }, [h('img', {}), nameLeaf]),
    h('div', { jsname: 'tgaKEf' }, [textLeaf]),
  ]);
  block.setSpeaker = (value) => {
    nameLeaf.textContent = value;
  };
  block.say = (value) => {
    textLeaf.textContent = value;
  };
  return block;
}

test('e2e: napisy Meeta -> Markdown z timestampami per osoba', () => {
  const captions = h('div', { class: 'a4cQT' }, []);
  const doc = makeDocument(h('body', {}, [captions]), { title: 'Standup zespołu - Google Meet' });

  const session = new Session(
    { title: 'Standup zespołu', source: MeetAdapter.id, startedAt: START },
    { silenceMs: 2000, mergeGapMs: 2500 },
  );
  const adapter = new MeetAdapter({ doc, store: session.store });

  // Meet trzyma okno ostatnich dwóch bloków i recyklinguje węzły.
  let block = null;
  let currentSpeaker = null;

  for (const [offset, speaker, text] of SCRIPT) {
    if (speaker !== currentSpeaker) {
      if (block && captions.children.length >= 2) captions.children[0].remove();
      block = liveBlock(speaker);
      captions.append(block);
      currentSpeaker = speaker;
    }
    block.say(text);
    adapter.tick(START + offset);
  }

  adapter.tick(START + 25_000);
  session.end(START + 30_000);

  const segments = session.segments;
  assert.deepEqual(
    segments.map((s) => s.speaker),
    ['Anna Kowalska', 'Jan Nowak', 'Marta Zielińska'],
  );
  assert.equal(segments[0].text, 'Dobra, zaczynamy dzisiejszy standup. Jan, lecisz pierwszy?');
  assert.equal(segments[1].text, 'Jasne, wczoraj domknąłem migrację bazy i dzisiaj biorę raporty');
  assert.equal(segments[2].text, 'Ja czekam na dostęp do stagingu.');
  assert.deepEqual(segments.map((s) => s.offsetMs), [1000, 9000, 20_000]);

  const markdown = session.toMarkdown();
  assert.match(markdown, /\*\*\[00:00:01\] Anna Kowalska\*\*/);
  assert.match(markdown, /\*\*\[00:00:09\] Jan Nowak\*\*/);
  assert.match(markdown, /\*\*\[00:00:20\] Marta Zielińska\*\*/);
  assert.match(markdown, /speakers: \["Anna Kowalska", "Jan Nowak", "Marta Zielińska"\]/);
  // Żadnego zdublowanego fragmentu z przewijanego okna.
  assert.equal(markdown.match(/wczoraj domknąłem migrację/g).length, 1);
});

test('e2e: sesja bez ani jednej wypowiedzi nie produkuje śmieci', () => {
  const doc = makeDocument(h('body', {}, [h('div', { class: 'a4cQT' }, [])]));
  const session = new Session({ title: 'Cisza', source: 'google-meet', startedAt: START });
  const adapter = new MeetAdapter({ doc, store: session.store });

  adapter.tick(START + 1000);
  adapter.tick(START + 5000);
  session.end(START + 10_000);

  assert.equal(session.segments.length, 0);
  assert.match(session.toMarkdown(), /Brak transkrypcji/);
});
