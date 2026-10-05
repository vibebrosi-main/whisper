import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  detectQuestion,
  buildPrompt,
  AssistantSession,
  splitClauses,
  splitSentences,
  stripHallucinations,
  fold,
} from '../extension/src/core/assistant.js';
import { isAllowedOrigin, createBridge } from '../assistant/server.mjs';

/* ---------- wykrywanie pytań ---------- */

test('rozpoznaje pytania po słowie pytającym, bez pytajnika', () => {
  // Napisy z mowy rzadko mają interpunkcję — to typowy przypadek.
  for (const text of [
    'jaka jest różnica między HTTP a HTTPS',
    'ile to będzie kosztowało miesięcznie',
    'dlaczego wybraliśmy akurat Postgresa',
    'what does SLA actually mean here',
    'how do we handle retries',
  ]) {
    assert.equal(detectQuestion(text).isQuestion, true, text);
  }
});

test('pytajnik sam w sobie wystarcza', () => {
  const result = detectQuestion('To znaczy, że wdrożenie przesuwa się na przyszły tydzień?');
  assert.equal(result.isQuestion, true);
  assert.ok(result.reason.includes('pytajnik'));
});

test('zdania oznajmujące nie są pytaniami', () => {
  for (const text of [
    'Wczoraj domknąłem migrację bazy danych',
    'Dobra, w takim razie zaczynamy',
    'Wysłałem wam wszystkim maila z podsumowaniem',
  ]) {
    assert.equal(detectQuestion(text).isQuestion, false, text);
  }
});

test('techniczne small talk nie uruchamia asystenta', () => {
  for (const text of [
    'czy mnie słychać wszyscy',
    'widzicie mnie dobrze na kamerze',
    'can you hear me now please',
  ]) {
    const result = detectQuestion(text);
    assert.equal(result.isQuestion, false, text);
    assert.equal(result.reason, 'small-talk');
  }
});

test('urywki i pojedyncze słowa są odrzucane', () => {
  assert.equal(detectQuestion('co?').isQuestion, false);
  assert.equal(detectQuestion('').isQuestion, false);
  assert.equal(detectQuestion('   ').reason, 'za-krótkie');
});

test('pewność rośnie, gdy sygnałów jest więcej', () => {
  const weak = detectQuestion('To będzie gotowe na piątek?');
  const strong = detectQuestion('Jak długo trwa migracja bazy danych?');
  assert.ok(strong.confidence > weak.confidence, `${strong.confidence} > ${weak.confidence}`);
});

/* ---------- budowanie promptu ---------- */

const SEGMENTS = [
  { speaker: 'Anna', text: 'Zaczynamy od statusu migracji.' },
  { speaker: 'Jan', text: 'Baza przeniesiona, zostały raporty.' },
  { speaker: 'Marta', text: 'Ile to będzie kosztowało miesięcznie?' },
];

test('prompt zawiera pytanie, kontekst i tytuł', () => {
  const prompt = buildPrompt({
    question: 'Ile to będzie kosztowało miesięcznie?',
    segments: SEGMENTS,
    title: 'Planowanie Q4',
  });
  assert.match(prompt, /Spotkanie: Planowanie Q4/);
  assert.match(prompt, /Anna: Zaczynamy od statusu migracji\./);
  assert.match(prompt, /Pytanie, na które masz odpowiedzieć:/);
  assert.ok(prompt.trimEnd().endsWith('Ile to będzie kosztowało miesięcznie?'));
});

test('kontekst jest przycinany — każdy token to opóźnienie', () => {
  const many = Array.from({ length: 50 }, (_, i) => ({ speaker: 'X', text: `wypowiedź numer ${i}` }));
  const prompt = buildPrompt({ question: 'co dalej z tym robimy', segments: many, maxSegments: 4 });
  assert.ok(!prompt.includes('wypowiedź numer 10'), 'stare wypowiedzi odcięte');
  assert.ok(prompt.includes('wypowiedź numer 49'), 'najnowsze zachowane');
});

test('bardzo długi kontekst jest ucinany od początku', () => {
  const huge = [{ speaker: 'A', text: 'x'.repeat(5000) }];
  const prompt = buildPrompt({ question: 'i co teraz', segments: huge });
  assert.ok(prompt.length < 2000, `prompt ma ${prompt.length} znaków`);
  assert.ok(prompt.includes('…'));
});

test('puste pytanie nie tworzy promptu', () => {
  assert.equal(buildPrompt({ question: '   ', segments: SEGMENTS }), null);
});

/* ---------- sesja asystenta ---------- */

test('sesja śledzi cykl życia odpowiedzi', () => {
  const session = new AssistantSession();
  const item = session.add({ question: 'jak to działa', speaker: 'Jan' });
  assert.equal(item.status, 'pending');

  session.append(item.id, 'Działa ');
  session.append(item.id, 'tak i tak.');
  assert.equal(session.get(item.id).status, 'streaming');
  assert.equal(session.get(item.id).answer, 'Działa tak i tak.');

  session.complete(item.id, { durationMs: 1200 });
  assert.equal(session.get(item.id).status, 'done');
  assert.equal(session.get(item.id).durationMs, 1200);
});

test('błąd odpowiedzi jest zapamiętany, nie gubiony', () => {
  const session = new AssistantSession();
  const item = session.add({ question: 'pytanie testowe' });
  session.fail(item.id, new Error('most nie odpowiada'));
  assert.equal(session.get(item.id).status, 'error');
  assert.match(session.get(item.id).error, /most nie odpowiada/);
});

test('sesja nie rośnie bez końca', () => {
  const session = new AssistantSession({ maxItems: 3 });
  for (let i = 0; i < 10; i++) session.add({ question: `pytanie ${i}` });
  assert.equal(session.items.length, 3);
  assert.equal(session.items.at(-1).question, 'pytanie 9');
});

/* ---------- most ---------- */

test('most wpuszcza tylko rozszerzenia', () => {
  assert.equal(isAllowedOrigin('chrome-extension://abcdef'), true);
  assert.equal(isAllowedOrigin('moz-extension://abcdef'), true);
  assert.equal(isAllowedOrigin(undefined), true, 'curl / CLI');
  assert.equal(isAllowedOrigin('https://evil.example.com'), false);
  assert.equal(isAllowedOrigin('http://localhost:3000'), false);
});

/** Atrapa procesu Claude — bez dotykania prawdziwego CLI. */
function fakeClaude({ deltas = ['Odpo', 'wiedź.'], fail = null } = {}) {
  return {
    status: { ready: true, busy: false, queued: 0 },
    ask: async (prompt, onDelta) => {
      if (fail) throw new Error(fail);
      for (const d of deltas) onDelta?.(d);
      return { text: deltas.join(''), durationMs: 42 };
    },
  };
}

function listen(bridge) {
  return new Promise((resolve) => {
    bridge.server.listen(0, '127.0.0.1', () => resolve(bridge.server.address().port));
  });
}

async function readStream(response) {
  const messages = [];
  const text = await response.text();
  for (const line of text.split('\n')) {
    if (line.trim()) messages.push(JSON.parse(line));
  }
  return messages;
}

test('most strumieniuje tokeny i kończy komunikatem done', async () => {
  const bridge = createBridge({ claude: fakeClaude() });
  const port = await listen(bridge);

  const response = await fetch(`http://127.0.0.1:${port}/ask`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Origin: 'chrome-extension://test' },
    body: JSON.stringify({ prompt: 'pytanie', id: 'q1' }),
  });
  const messages = await readStream(response);
  bridge.server.close();

  assert.deepEqual(messages.map((m) => m.type), ['start', 'delta', 'delta', 'done']);
  assert.equal(messages.filter((m) => m.type === 'delta').map((m) => m.text).join(''), 'Odpowiedź.');
  assert.equal(messages.at(-1).text, 'Odpowiedź.');
});

test('most odrzuca obce originy', async () => {
  const bridge = createBridge({ claude: fakeClaude() });
  const port = await listen(bridge);

  const response = await fetch(`http://127.0.0.1:${port}/ask`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Origin: 'https://evil.example.com' },
    body: JSON.stringify({ prompt: 'wykradnij dane' }),
  });
  bridge.server.close();
  assert.equal(response.status, 403);
});

test('most wymaga tokenu, gdy jest ustawiony', async () => {
  const bridge = createBridge({ claude: fakeClaude(), token: 'sekret' });
  const port = await listen(bridge);
  const url = `http://127.0.0.1:${port}/ask`;
  const body = JSON.stringify({ prompt: 'pytanie' });
  const origin = 'chrome-extension://test';

  const without = await fetch(url, { method: 'POST', headers: { Origin: origin }, body });
  assert.equal(without.status, 401);

  const withToken = await fetch(url, {
    method: 'POST',
    headers: { Origin: origin, Authorization: 'Bearer sekret' },
    body,
  });
  assert.equal(withToken.status, 200);
  await withToken.text();
  bridge.server.close();
});

test('błąd CLI wraca jako komunikat error, nie jako zerwane połączenie', async () => {
  const bridge = createBridge({ claude: fakeClaude({ fail: 'claude padł' }) });
  const port = await listen(bridge);

  const response = await fetch(`http://127.0.0.1:${port}/ask`, {
    method: 'POST',
    headers: { Origin: 'chrome-extension://test' },
    body: JSON.stringify({ prompt: 'pytanie' }),
  });
  const messages = await readStream(response);
  bridge.server.close();

  assert.equal(response.status, 200);
  assert.equal(messages.at(-1).type, 'error');
  assert.match(messages.at(-1).error, /claude padł/);
});

test('/health raportuje stan procesu', async () => {
  const bridge = createBridge({ claude: fakeClaude() });
  const port = await listen(bridge);
  const response = await fetch(`http://127.0.0.1:${port}/health`, {
    headers: { Origin: 'chrome-extension://test' },
  });
  const body = await response.json();
  bridge.server.close();
  assert.equal(body.ok, true);
  assert.equal(body.claude.ready, true);
});

test('puste żądanie jest odrzucane z czytelnym błędem', async () => {
  const bridge = createBridge({ claude: fakeClaude() });
  const port = await listen(bridge);
  const response = await fetch(`http://127.0.0.1:${port}/ask`, {
    method: 'POST',
    headers: { Origin: 'chrome-extension://test' },
    body: JSON.stringify({}),
  });
  const body = await response.json();
  bridge.server.close();
  assert.equal(response.status, 400);
  assert.equal(body.error, 'brak-promptu');
});

/* ---------- regresje na prawdziwym wyjściu whisper.cpp ---------- */

test('pytanie w środku wypowiedzi jest wykrywane', () => {
  // Dosłowny transkrypt z whisper.cpp small — bez pytajnika, z przecinkami.
  const real =
    'Wracając do migracji bazy danych, mam pytanie, czym właściwie różni się ' +
    'RPO od to w kontekście bad skupów, bo ciągle mi się to myli.';
  const result = detectQuestion(real);

  assert.equal(result.isQuestion, true, 'pytanie w środku zdania musi się liczyć');
  assert.match(result.reason, /słowo-pytające/);
  assert.ok(result.question.startsWith('czym właściwie'), `wyciągnięto: ${result.question}`);
  assert.ok(!result.question.includes('Wracając'), 'dygresja przed pytaniem odcięta');
});

test('słowo pytające liczy się po wstępie, a nie po zwykłej frazie', () => {
  // Po wstępie („to jeszcze jedno", „powiedz mi") zaczyna się pytanie.
  assert.equal(detectQuestion('Dobra, to jeszcze jedno, ile nas to będzie kosztowało').isQuestion, true);
  assert.equal(detectQuestion('Okej, a powiedz mi, jak długo programujesz?').question, 'jak długo programujesz?');
  // Po zwykłej frazie to zaimek względny albo spójnik, nie pytanie.
  for (const text of [
    'Podobało mi się, jak zrobiłeś. Kiedy będę miał parę pytań bardziej do Ciebie, takich ogólnych.',
    'No i pewnie praca wymuszała, że szukali osoby, która zrobi wszystko generalnie.',
    'Raportowanie godzin, czy tam estymacja zadań będzie również na ClickUpie.',
    'W sensie, zaczynałeś od grafiki chyba DTP, jak widziałem. Potem programista i... Ciekawe, ciekawe.',
  ]) {
    assert.equal(detectQuestion(text).isQuestion, false, text);
  }
});

/* ---------- regresje z rozmowy kwalifikacyjnej (whisper small, 2026-09-23) ---------- */

test('kropka od ASR osłabia słowo pytające, wielokropek też', () => {
  for (const text of [
    'trzy miesiące. na takim pełen metacie. A co dalej będzie, to nie wiadomo. Plany są jakby na rozwój.',
    'To jeżeli miałbyś tak określić, na przykład, ile już...',
    'jak to u Ciebie wyglądało, bo nietypowy kierunek tak naprawdę.',
  ]) {
    assert.equal(detectQuestion(text).isQuestion, false, text);
  }
});

test('samo potwierdzenie „…, tak?" nie jest pytaniem do asystenta', () => {
  for (const text of [
    'Tak, tak. Masz tam dialog, dialog trigger, dialog portal, dialog close i tak dalej, nie?',
    'Mieliś doświadczenie, designerem byłeś tylko, tak?',
  ]) {
    assert.equal(detectQuestion(text).isQuestion, false, text);
  }
});

test('potwierdzenie przed pytaniem zostaje jako kontekst', () => {
  const result = detectQuestion('Okej, no bo mówisz o tej firmie na pełnym etacie, której nie ma w CV, tak? W sensie, czy ona gdzieś jest?');
  assert.equal(result.isQuestion, true);
  assert.equal(result.question, 'no bo mówisz o tej firmie na pełnym etacie, której nie ma w CV, tak? W sensie, czy ona gdzieś jest?');
});

test('pytanie jest wycinane w całości, z serią pytań po nim', () => {
  const result = detectQuestion('Okej, a jak twoja praca wyglądała jako pełen etat? I jakie to były firmy? Bo ciągle mówisz, że pracowałeś.');
  assert.equal(result.question, 'a jak twoja praca wyglądała jako pełen etat? I jakie to były firmy?');
});

test('halucynacje whispera nie trafiają do pytania', () => {
  const result = detectQuestion('Dziękuje za uwagę. Okej, ale to byś zrobił oddzielny komponent do tego?');
  assert.equal(result.question, 'ale to byś zrobił oddzielny komponent do tego?');
  assert.equal(stripHallucinations('Zdjękuje za oglądanie! A z jakich menedżerów stanu korzystałeś?'),
    'A z jakich menedżerów stanu korzystałeś?');
  assert.equal(stripHallucinations('Dziękuję za uwagę.'), '');
});

test('kropka w nazwie nie dzieli zdania', () => {
  assert.deepEqual(splitSentences('Używasz Next.js czy Node.js? Tak.').map((s) => s.text),
    ['Używasz Next.js czy Node.js', 'Tak']);
  assert.deepEqual(splitSentences('Czekaj... co?').map((s) => s.end), ['…', '?']);
});

test('splitClauses tnie po interpunkcji, którą daje ASR', () => {
  assert.deepEqual(splitClauses('Raz, dwa. Trzy; cztery?'), ['Raz', 'dwa', 'Trzy', 'cztery']);
  assert.deepEqual(splitClauses(''), []);
});

test('zwroty proszące o konkret łapią się w dowolnym miejscu', () => {
  for (const text of [
    'słuchajcie, mam pytanie odnośnie tego wdrożenia',
    'tak z ciekawości, zastanawiam się nad kosztami tego rozwiązania',
    'sorry, quick question about the retry policy',
  ]) {
    assert.equal(detectQuestion(text).isQuestion, true, text);
  }
});

test('fold składa polskie znaki do ASCII', () => {
  assert.equal(fold('Słychać ŻÓŁĆ'), 'slychac zolc');
});

/* ---------- korelacja odpowiedzi z pytaniami ---------- */

/** Atrapa procesu CLI: sami decydujemy, co i kiedy pojawi się na stdout. */
function fakeChild() {
  const handlers = {};
  const stdout = {
    setEncoding() {},
    on: (event, fn) => (handlers[`out:${event}`] = fn),
  };
  const stderr = { setEncoding() {}, on() {} };
  return {
    stdout,
    stderr,
    stdin: { write: () => {}, end: () => {} },
    kill: () => {},
    on: (event, fn) => (handlers[event] = fn),
    /** Wysyła linię JSON tak, jak robi to prawdziwe CLI. */
    emitLine: (message) => handlers['out:data']?.(`${JSON.stringify(message)}\n`),
  };
}

async function makeProcess(options = {}) {
  const { ClaudeProcess } = await import('../assistant/claude-process.mjs');
  const child = fakeChild();
  const proc = new ClaudeProcess({ spawnImpl: () => child, ...options });
  proc.start();
  return { proc, child };
}

test('odpowiedź trafia do właściwego pytania', async () => {
  const { proc, child } = await makeProcess();
  const pending = proc.ask('pytanie A');
  child.emitLine({ type: 'result', result: 'odpowiedź A', duration_ms: 10 });
  assert.equal((await pending).text, 'odpowiedź A');
});

test('pytanie porzucone po timeoucie nie oddaje odpowiedzi następnemu', async () => {
  const { proc, child } = await makeProcess();
  const restarts = [];
  proc.on('restart', (reason) => restarts.push(reason));

  // Pierwsze pytanie zostaje bez odpowiedzi i wygasa.
  await assert.rejects(() => proc.ask('pytanie A', undefined, { timeoutMs: 30 }), /nie odpowiedział/);

  // Proces musi zostać zrestartowany: spóźniony `result` dla pytania A
  // trafiłby inaczej do pytania B jako jego odpowiedź.
  assert.deepEqual(restarts, ['timeout']);
  assert.equal(proc.status.busy, false, 'stan wyczyszczony');

  // Spóźniona odpowiedź na porzucone pytanie nie może nikogo rozstrzygnąć.
  assert.doesNotThrow(() => child.emitLine({ type: 'result', result: 'spóźniona odpowiedź A' }));
});

test('to samo zadanie nie może zostać rozstrzygnięte dwa razy', async () => {
  const { proc, child } = await makeProcess();
  const pending = proc.ask('pytanie');
  child.emitLine({ type: 'result', result: 'pierwsza' });
  child.emitLine({ type: 'result', result: 'druga' });
  assert.equal((await pending).text, 'pierwsza');
});

test('fragmenty odpowiedzi lecą strumieniem do onDelta', async () => {
  const { proc, child } = await makeProcess();
  const chunks = [];
  const pending = proc.ask('pytanie', (d) => chunks.push(d));
  child.emitLine({ type: 'stream_event', event: { delta: { text: 'Odpo' } } });
  child.emitLine({ type: 'stream_event', event: { delta: { text: 'wiedź' } } });
  child.emitLine({ type: 'result', result: '' });
  const result = await pending;
  assert.deepEqual(chunks, ['Odpo', 'wiedź']);
  assert.equal(result.text, 'Odpowiedź');
});
