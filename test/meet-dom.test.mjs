import { test } from 'node:test';
import assert from 'node:assert/strict';
import { h, t, makeDocument } from './fake-dom.mjs';
import {
  parseBlock,
  collectBlocks,
  findCaptionRoot,
  captionsState,
  findCaptionsButton,
  meetingCode,
  meetingTitle,
  isNameLike,
  commonAncestor,
  containsNode,
} from '../extension/src/adapters/meet/dom.js';

/** Układ zgodny z aktualnym Meetem (jsname + znane klasy). */
function meetBlock(name, text) {
  return h('div', { jsname: 'dsyhDe', class: 'nMcdL bj4p3b' }, [
    h('div', { class: 'KcIKyf jxFHg' }, [
      h('img', { class: 'r6DyN', src: 'avatar.png' }),
      t('div', name, { class: 'zs7s8d jxFHg' }),
    ]),
    h('div', { jsname: 'tgaKEf', class: 'bh44bd VbkSUe' }, [t('span', text)]),
  ]);
}

/** Ten sam sens, ale bez jsname i ze zmienionymi klasami — symulacja zmiany w Meecie. */
function churnedBlock(name, text) {
  return h('div', { class: 'xX1yZ2' }, [
    h('div', { class: 'qQ9aB3' }, [h('img', { src: 'avatar.png' }), t('div', name)]),
    t('div', text, { class: 'pP4cD5' }),
  ]);
}

test('parseBlock czyta mówcę i tekst z aktualnej struktury Meet', () => {
  const parsed = parseBlock(meetBlock('Anna Kowalska', 'Cześć wszystkim, zaczynamy.'));
  assert.deepEqual(parsed, { speaker: 'Anna Kowalska', text: 'Cześć wszystkim, zaczynamy.' });
});

test('parseBlock działa po zmianie klas i utracie jsname', () => {
  const parsed = parseBlock(churnedBlock('Jan Nowak', 'Hej, słychać mnie?'));
  assert.deepEqual(parsed, { speaker: 'Jan Nowak', text: 'Hej, słychać mnie?' });
});

test('parseBlock skleja tekst rozbity na kilka spanów', () => {
  const block = h('div', { jsname: 'dsyhDe' }, [
    t('div', 'Ala', { class: 'zs7s8d' }),
    h('div', { jsname: 'tgaKEf' }, [t('span', 'pierwsza część'), t('span', 'druga część')]),
  ]);
  assert.equal(parseBlock(block).text, 'pierwsza część druga część');
});

test('parseBlock zwraca null dla bloków bez wypowiedzi', () => {
  assert.equal(parseBlock(h('div', {}, [t('div', 'Anna Kowalska', { class: 'zs7s8d' })])), null);
  assert.equal(parseBlock(h('div', {}, [])), null);
});

test('parseBlock nie bierze zdania jako imienia', () => {
  const block = h('div', {}, [t('div', 'To jest całe zdanie, które ktoś powiedział.')]);
  assert.equal(parseBlock(block), null);
});

test('isNameLike odróżnia etykietę od wypowiedzi', () => {
  assert.equal(isNameLike('Anna Kowalska'), true);
  assert.equal(isNameLike('Jan Nowak (Gość)'), true);
  assert.equal(isNameLike('Dzień dobry, zaczynamy spotkanie.'), false);
  assert.equal(isNameLike(''), false);
});

test('collectBlocks znajduje bloki po jsname', () => {
  const root = h('div', { class: 'a4cQT' }, [
    h('div', {}, [meetBlock('Anna', 'raz'), meetBlock('Jan', 'dwa')]),
  ]);
  const blocks = collectBlocks(root);
  assert.equal(blocks.length, 2);
  assert.deepEqual(blocks.map((b) => parseBlock(b).speaker), ['Anna', 'Jan']);
});

test('collectBlocks wraca do heurystyki strukturalnej bez jsname', () => {
  const root = h('div', { 'aria-live': 'polite' }, [
    churnedBlock('Anna', 'raz dwa trzy'),
    churnedBlock('Jan', 'cztery pięć'),
  ]);
  const blocks = collectBlocks(root);
  assert.equal(blocks.length, 2);
  assert.deepEqual(blocks.map((b) => parseBlock(b).text), ['raz dwa trzy', 'cztery pięć']);
});

test('findCaptionRoot: kontener po jsname bloku', () => {
  const wrapper = h('div', {}, [meetBlock('Anna', 'raz')]);
  const doc = makeDocument(h('body', {}, [h('div', { class: 'a4cQT' }, [wrapper])]));
  assert.equal(findCaptionRoot(doc), wrapper);
});

test('findCaptionRoot: aria-live jako fallback, pomija puste regiony', () => {
  const empty = h('div', { 'aria-live': 'polite' }, [t('span', 'Napisy wyłączone')]);
  const real = h('div', { 'aria-live': 'polite' }, [churnedBlock('Anna', 'coś mówię teraz')]);
  const doc = makeDocument(h('body', {}, [empty, real]));
  assert.equal(findCaptionRoot(doc), real);
});

test('findCaptionRoot zwraca null gdy napisów nie ma', () => {
  const doc = makeDocument(h('body', {}, [h('div', {}, [t('span', 'nic tu nie ma')])]));
  assert.equal(findCaptionRoot(doc), null);
});

test('captionsState rozpoznaje stan po etykiecie w różnych językach', () => {
  const on = makeDocument(h('body', {}, [h('button', { 'aria-label': 'Turn off captions' })]));
  const off = makeDocument(h('body', {}, [h('button', { 'aria-label': 'Włącz napisy' })]));
  const onPl = makeDocument(h('body', {}, [h('button', { 'aria-label': 'Wyłącz napisy' })]));
  const none = makeDocument(h('body', {}, [h('button', { 'aria-label': 'Wycisz mikrofon' })]));
  assert.equal(captionsState(on), 'on');
  assert.equal(captionsState(off), 'off');
  assert.equal(captionsState(onPl), 'on');
  assert.equal(captionsState(none), 'unknown');
});

test('captionsState woli aria-pressed od etykiety', () => {
  const doc = makeDocument(
    h('body', {}, [h('button', { 'aria-label': 'Napisy', 'aria-pressed': 'true' })]),
  );
  assert.equal(captionsState(doc), 'on');
  assert.ok(findCaptionsButton(doc));
});

test('meetingCode i meetingTitle', () => {
  assert.equal(meetingCode('https://meet.google.com/abc-defg-hij?hs=1'), 'abc-defg-hij');
  assert.equal(meetingCode('https://example.com'), '');
  const doc = makeDocument(h('body', {}), { title: 'Standup zespołu - Google Meet' });
  assert.equal(meetingTitle(doc, doc.location.href), 'Standup zespołu');
  const bare = makeDocument(h('body', {}), { title: 'Meet' });
  assert.equal(meetingTitle(bare, bare.location.href), 'Google Meet abc-defg-hij');
});

test('findCaptionRoot bierze wspólnego przodka, gdy każdy mówca ma własny wrapper', () => {
  const a = meetBlock('Anna', 'raz');
  const b = meetBlock('Jan', 'dwa');
  const shared = h('div', { class: 'TBMuR' }, [h('div', {}, [a]), h('div', {}, [b])]);
  const doc = makeDocument(h('body', {}, [h('div', { class: 'a4cQT' }, [shared])]));

  const root = findCaptionRoot(doc);
  assert.equal(root, shared);
  assert.equal(collectBlocks(root).length, 2);
});

test('commonAncestor i containsNode', () => {
  const leafA = t('div', 'a');
  const leafB = t('div', 'b');
  const parent = h('div', {}, [leafA, leafB]);
  const root = h('div', {}, [parent]);

  assert.equal(commonAncestor([leafA, leafB]), parent);
  assert.equal(commonAncestor([leafA]), parent);
  assert.equal(commonAncestor([]), null);
  assert.equal(containsNode(root, leafA), true);
  assert.equal(containsNode(parent, root), false);
});
