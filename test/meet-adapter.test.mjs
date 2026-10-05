import { test } from 'node:test';
import assert from 'node:assert/strict';
import { h, t, makeDocument } from './fake-dom.mjs';
import { MeetAdapter } from '../extension/src/adapters/meet/index.js';
import { TranscriptStore } from '../extension/src/core/transcript.js';

const T0 = 2_000_000;

/** Blok napisów, którego tekst da się podmieniać jak robi to Meet. */
function liveBlock(name) {
  const textLeaf = t('span', '');
  const block = h('div', { jsname: 'dsyhDe' }, [
    h('div', { class: 'KcIKyf' }, [h('img', {}), t('div', name, { class: 'zs7s8d' })]),
    h('div', { jsname: 'tgaKEf' }, [textLeaf]),
  ]);
  block.say = (value) => {
    textLeaf.textContent = value;
    return block;
  };
  return block;
}

function setup() {
  const captions = h('div', { class: 'a4cQT' }, []);
  const body = h('body', {}, [h('button', { 'aria-label': 'Wyłącz napisy' }), captions]);
  const doc = makeDocument(body, { title: 'Standup - Google Meet' });
  const store = new TranscriptStore({ startedAt: T0, silenceMs: 1500, mergeGapMs: 2000 });
  const adapter = new MeetAdapter({ doc, store });
  return { captions, doc, store, adapter };
}

test('pełna sesja: strumień napisów -> segmenty per osoba', () => {
  const { captions, store, adapter } = setup();

  // Napisy jeszcze nie ruszyły.
  adapter.tick(T0);
  assert.equal(store.isEmpty, true);

  // Anna zaczyna mówić, Meet dopisuje tekst w kolejnych klatkach.
  const anna = liveBlock('Anna Kowalska');
  captions.append(anna);
  anna.say('Cześć');
  adapter.tick(T0 + 1000);
  anna.say('Cześć wszystkim');
  adapter.tick(T0 + 1600);
  anna.say('Cześć wszystkim, zaczynamy standup');
  adapter.tick(T0 + 2400);

  assert.equal(store.segments.length, 1);
  assert.equal(store.segments[0].text, 'Cześć wszystkim, zaczynamy standup');
  assert.equal(store.segments[0].final, false);

  // Jan odpowiada w nowym bloku.
  const jan = liveBlock('Jan Nowak');
  captions.append(jan);
  jan.say('Hej, słychać mnie?');
  adapter.tick(T0 + 5000);

  assert.deepEqual(store.segments.map((s) => s.speaker), ['Anna Kowalska', 'Jan Nowak']);
  // Anna milczy od 2400 ms -> jej segment domknięty przez ciszę.
  assert.equal(store.segments[0].final, true);

  // Blok Anny wypada z DOM (Meet przewinął napisy).
  anna.remove();
  adapter.tick(T0 + 6000);
  assert.equal(store.segments.length, 2);
  assert.equal(store.segments[0].text, 'Cześć wszystkim, zaczynamy standup');

  // Offsety liczone od startu sesji.
  assert.deepEqual(store.segments.map((s) => s.offsetMs), [1000, 5000]);
});

test('ten sam blok DOM przejęty przez innego mówcę rozdziela wypowiedzi', () => {
  const { captions, store, adapter } = setup();
  const block = liveBlock('Anna Kowalska');
  captions.append(block);
  block.say('pierwsza wypowiedź');
  adapter.tick(T0);

  // Meet recyklinguje węzeł: podmienia imię i tekst.
  block.children[0].children[1].textContent = 'Jan Nowak';
  block.say('druga wypowiedź');
  adapter.tick(T0 + 300);

  assert.deepEqual(
    store.segments.map((s) => [s.speaker, s.text]),
    [
      ['Anna Kowalska', 'pierwsza wypowiedź'],
      ['Jan Nowak', 'druga wypowiedź'],
    ],
  );
});

test('przewijane okno tekstu nie duplikuje treści', () => {
  const { captions, store, adapter } = setup();
  const block = liveBlock('Anna Kowalska');
  captions.append(block);
  block.say('mamy dzisiaj trzy tematy do omówienia');
  adapter.tick(T0);
  // Meet ucina początek i dokłada dalszy ciąg.
  block.say('trzy tematy do omówienia i jeden do decyzji');
  adapter.tick(T0 + 400);

  assert.equal(
    store.segments[0].text,
    'mamy dzisiaj trzy tematy do omówienia i jeden do decyzji',
  );
});

test('wyłączenie napisów w trakcie domyka otwarte segmenty', () => {
  const { captions, store, adapter } = setup();
  const block = liveBlock('Anna Kowalska');
  captions.append(block);
  block.say('coś mówię');
  adapter.tick(T0);
  assert.equal(store.segments[0].final, false);

  block.remove();
  adapter.tick(T0 + 200);
  assert.equal(store.segments[0].final, true);
});

test('status raportuje stan napisów i tytuł spotkania', () => {
  const { adapter } = setup();
  const status = adapter.status;
  assert.equal(status.captions, 'on');
  assert.equal(status.title, 'Standup');
  assert.equal(status.code, 'abc-defg-hij');
});

test('enableCaptions klika przycisk tylko gdy napisy są wyłączone', () => {
  const captions = h('div', { class: 'a4cQT' }, []);
  let clicks = 0;
  const button = h('button', { 'aria-label': 'Włącz napisy' });
  button.click = () => {
    clicks++;
    button.setAttribute('aria-label', 'Wyłącz napisy');
  };
  const doc = makeDocument(h('body', {}, [button, captions]));
  const adapter = new MeetAdapter({ doc, store: new TranscriptStore({ startedAt: T0 }) });

  assert.equal(adapter.enableCaptions(), true);
  assert.equal(clicks, 1);
  assert.equal(adapter.enableCaptions(), false);
  assert.equal(clicks, 1);
});

test('onChange odpala się tylko przy realnej zmianie transkryptu', () => {
  const captions = h('div', { class: 'a4cQT' }, []);
  const doc = makeDocument(h('body', {}, [captions]));
  const store = new TranscriptStore({ startedAt: T0, silenceMs: 10_000 });
  let calls = 0;
  const adapter = new MeetAdapter({ doc, store, onChange: () => calls++ });

  const block = liveBlock('Anna');
  captions.append(block);
  block.say('tekst');
  adapter.tick(T0);
  assert.equal(calls, 1);

  adapter.tick(T0 + 100);
  adapter.tick(T0 + 200);
  assert.equal(calls, 1, 'brak zmian => brak powiadomień');

  block.say('tekst i coś jeszcze');
  adapter.tick(T0 + 300);
  assert.equal(calls, 2);
});

test('nowy kontener napisów po ponownym włączeniu jest wykrywany', () => {
  const { doc, captions, store, adapter } = setup();
  const first = liveBlock('Anna Kowalska');
  captions.append(first);
  first.say('pierwsza runda');
  adapter.tick(T0);
  assert.equal(store.segments.length, 1);

  // Meet wyrzuca cały kontener i buduje go od nowa.
  captions.remove();
  adapter.tick(T0 + 3000);

  const fresh = h('div', { class: 'a4cQT' }, []);
  doc.body.append(fresh);
  const second = liveBlock('Jan Nowak');
  fresh.append(second);
  second.say('druga runda');
  adapter.tick(T0 + 6000);

  assert.deepEqual(
    store.segments.map((s) => [s.speaker, s.text]),
    [
      ['Anna Kowalska', 'pierwsza runda'],
      ['Jan Nowak', 'druga runda'],
    ],
  );
});
