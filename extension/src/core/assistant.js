/**
 * Logika asystenta: co jest pytaniem i jak zbudować z transkrypcji prompt.
 *
 * Czysta i testowalna — nie wie nic o HTTP, WebSocketach ani o Claude Code.
 */

import { normalize, stripHallucinations } from './text.js';

export { stripHallucinations };

/** Słowa otwierające pytanie. Pytajnika w mowie nie ma — napisy go nie dają. */
const QUESTION_OPENERS = {
  pl: [
    'czy', 'jak', 'jaki', 'jaka', 'jakie', 'jakim', 'jakich', 'ile', 'kiedy', 'gdzie',
    'kto', 'komu', 'kogo', 'co', 'czemu', 'dlaczego', 'po co', 'skąd', 'dokąd', 'który',
    'która', 'które', 'czym', 'w czym', 'na czym',
    // Formy odmienione: bez nich „od której wersji" i „jakiego typu" przepadały.
    'której', 'którego', 'którym', 'których', 'jakiego', 'jakiej', 'jakimi', 'ilu',
  ],
  en: [
    'is', 'are', 'was', 'were', 'do', 'does', 'did', 'can', 'could', 'should', 'would',
    'will', 'what', 'why', 'how', 'when', 'where', 'who', 'which', 'whose', 'whom',
  ],
};

/**
 * Zwroty, po których ktoś prosi o konkret — szukane w dowolnym miejscu.
 * Zapisane bez znaków diakrytycznych, bo porównujemy tekst złożony do ASCII.
 */
const ASK_PHRASES = [
  'mam pytanie', 'pytanie do', 'wie ktos', 'wiesz moze', 'czy ktos wie',
  'jak to dziala', 'co to znaczy', 'zastanawiam sie', 'nie wiem czy',
  'ciekawi mnie', 'wytlumacz', 'przypomnij mi',
  // Rozmowa rekrutacyjna to w połowie polecenia, nie pytania: „opowiedz mi
  // o projekcie", „przybliż, za co odpowiadałeś". Bez pytajnika i bez słowa
  // pytającego na początku przepadały wszystkie.
  'opowiedz', 'opowiesz', 'opisz', 'przybliz', 'podziel sie', 'pochwal sie',
  'powiedz mi o', 'powiedz cos o', 'dlaczego', 'od kiedy', 'jak wyglada',
  'jesli mialbys', 'jesli mialabys', 'gdybys mial', 'gdybys miala', 'zgadza sie',
  // Prośba o potwierdzenie warunków: „…do końca roku jest dla ciebie okej."
  'dla ciebie ok', 'dla ciebie okej', 'pasuje ci', 'odpowiada ci', 'ci pasuje', 'ci odpowiada',
  // Zaproszenie do pytań: „jeżeli masz jakieś pytania, śmiało". Podpowiedzią
  // są wtedy pytania do zadania, nie odpowiedź.
  'masz jakies', 'masz pytania', 'macie jakies pytania', 'chcialbys zadac',
  'chcialbys zapytac', 'chcesz o cos zapytac', 'any questions',
  'tell me about', 'walk me through', 'describe',
  'anyone know', 'does anyone', 'what does', 'how do we', 'quick question',
];

/**
 * Składa tekst do ASCII: małe litery, bez znaków diakrytycznych.
 *
 * Bez tego wzorce są kruche z dwóch powodów naraz: w mowie szyk jest swobodny,
 * a `\b` w JS nie stawia granicy wokół polskich liter (`ć`, `ł` nie są `\w`),
 * więc `\bs\u0142ycha\u0107\b` nie dopasowuje się do niczego.
 */
export function fold(text) {
  return String(text ?? '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/\u0142/g, 'l');
}

/** Pytania techniczno-organizacyjne, na które asystent nie ma czego odpowiadać. */
const SMALL_TALK_PATTERNS = [
  /\b(slychac|slyszysz|slyszycie|slysze|slyszymy)\b/,
  // „Widać mój ekran?" tak, „Gdzie się widzisz za pięć lat?" nie.
  /\b(widac|widzisz|widzicie|widze)\b.*\b(mnie|nas|cie|was|ekran\w*|prezentacj\w*|kamer\w*)\b/,
  /\b(hear|see)\s+(me|my\s+screen|you)\b/,
  /\bhalo+\b/,
  /\bjestes\s+tam\b/,
  /\b(mozemy|to)\s+zaczyna(my|c)\b/,
  /\bwszyscy\s+(sa|juz\s+sa)\b/,
  /\b(dziala|dziela)\s+(mikrofon|kamera|dzwiek)\b/,
];

const MIN_QUESTION_CHARS = 8;
const MIN_QUESTION_WORDS = 3;

/**
 * Dzieli wypowiedź na frazy.
 *
 * W prawdziwej mowie pytanie prawie nigdy nie stoi na początku wypowiedzi:
 * „Wracając do migracji, mam pytanie, czym różni się RPO od RTO". Sprawdzanie
 * tylko pierwszego słowa całości gubiło takie przypadki — a to one dominują.
 */
export function splitClauses(text) {
  return splitClausesWithEnd(text).map((c) => c.text);
}

/**
 * Jak `splitClauses`, ale zachowuje informację, czy fraza kończyła się
 * pytajnikiem. Bez tego nie da się powiedzieć, GDZIE pytanie się kończy —
 * a branie wszystkiego do końca wypowiedzi wciągało do promptu odpowiedź,
 * która po nim padła.
 */
export function splitClausesWithEnd(text) {
  const out = [];
  const source = String(text ?? '');
  let buffer = '';
  for (let i = 0; i < source.length; i++) {
    const ch = source[i];
    if (',.;!?'.includes(ch)) {
      const trimmed = buffer.trim();
      if (trimmed) out.push({ text: trimmed, endsQuestion: ch === '?' });
      buffer = '';
      continue;
    }
    buffer += ch;
  }
  const tail = buffer.trim();
  if (tail) out.push({ text: tail, endsQuestion: false });
  return out;
}

/** Twardy limit długości pytania. Prompt ma być krótki, nie kompletny. */
const MAX_QUESTION_CHARS = 220;
/**
 * Pytanie krótsze niż to samo nic nie znaczy („Zgadza się?", „Jakie były?")
 * i dostaje zdanie, które stoi przed nim.
 */
const MIN_STANDALONE_CHARS = 30;

const ALL_OPENERS = [...QUESTION_OPENERS.pl, ...QUESTION_OPENERS.en].map((o) => fold(o).split(' '));

/**
 * Słówka, które w mowie stoją PRZED właściwym słowem pytającym: „od której
 * wersji", „w czym piszesz". Dopuszczamy najwyżej jedno.
 */
const LEADING_PARTICLES = new Set([
  'od', 'do', 'w', 'na', 'z', 'za', 'po', 'przy', 'dla', 'o', 'u',
]);

/**
 * Słowa wypełniające i wstępy, po których dopiero zaczyna się treść:
 * „Okej, dobra, a powiedz mi, jak długo programujesz?". Fraza złożona
 * wyłącznie z nich jest wstępem, a nie treścią, i nie liczy się jako
 * początek zdania.
 */
const FILLER_WORDS = new Set([
  'okej', 'ok', 'okay', 'dobra', 'dobrze', 'no', 'tak', 'mhm', 'hmm', 'ehm', 'eh', 'yyy', 'aha',
  'fajnie', 'super', 'jasne', 'swietnie', 'sluchaj', 'wiesz', 'czekaj', 'hej',
  'a', 'i', 'to', 'wiec', 'ale', 'czyli', 'jeszcze', 'jedno', 'jakby', 'teraz',
  'powiedz', 'powiedzcie', 'mi', 'nam', 'mam', 'pytanie', 'pytanko', 'w', 'sensie', 'znaczy',
  'na', 'przyklad', 'generalnie', 'ogolnie', 'mozesz', 'mozecie', 'powiedziec',
  // „Nie, po prostu jakie…" - sprzeciw przed właściwym pytaniem.
  'nie',
  'so', 'well', 'okay', 'alright', 'right', 'tell', 'me', 'question',
]);

/**
 * Czasownik w 2. osobie („stworzyłeś", „zrobiłabyś") - zdanie jest skierowane
 * do rozmówcy. Z kropką od ASR słowo pytające samo nie wystarcza, ale razem
 * z takim czasownikiem to pytanie: „jakie featury stworzyłeś, co napisałeś."
 * Urwane („…ile już...") nie: tam trzeba poczekać na resztę.
 */
const SECOND_PERSON = /^(?:\p{L}{3,}(?:les|las|lbys|labys|esz|isz|ysz|asz)|jestes)$/u;
/** „Jak widzisz, …", „jak wiesz, …" - wtrącenia, nie pytania. */
const ASIDE_VERBS = new Set(['widzisz', 'wiesz', 'slyszysz', 'rozumiesz', 'mowisz', 'pamietasz', 'mowiles', 'wspominales']);
const isSecondPerson = (w) => SECOND_PERSON.test(w) && !ASIDE_VERBS.has(w);

/** Końcówki, które z oznajmienia robią prośbę o potwierdzenie: „…, tak?". */
const CONFIRMATION_TAGS = new Set(['tak', 'nie', 'prawda', 'no nie', 'nie prawda', 'right', 'yeah']);

/**
 * Dzieli wypowiedź na zdania, pamiętając, czym się kończyły: `?`, `.`, `!`,
 * `…` (urwane) albo nic (koniec wypowiedzi bez interpunkcji).
 *
 * Kropka kończy zdanie tylko przed spacją albo na końcu: „Next.js" i „40 ml."
 * to nie są dwa zdania. Dwie kropki i więcej to wielokropek.
 */
export function splitSentences(text) {
  const out = [];
  const source = String(text ?? '');
  let buffer = '';
  const push = (end) => {
    const trimmed = buffer.trim();
    if (trimmed) out.push({ text: trimmed, end });
    buffer = '';
  };
  for (let i = 0; i < source.length; i++) {
    const ch = source[i];
    if (ch === '?' || ch === '!') {
      let end = ch;
      while (source[i + 1] === '?' || source[i + 1] === '!') { if (source[i + 1] === '?') end = '?'; i++; }
      push(end);
    } else if (ch === '…') {
      push('…');
    } else if (ch === '.') {
      let run = 1;
      while (source[i + run] === '.') run++;
      if (run >= 2) { i += run - 1; push('…'); continue; }
      const next = source[i + 1];
      if (next === undefined || /\s/.test(next)) push('.');
      else buffer += ch;
    } else {
      buffer += ch;
    }
  }
  push('');
  return out;
}

const words = (text) => fold(text).split(/[^a-z0-9']+/).filter(Boolean);
const isFillerClause = (clause) => words(clause).every((w) => FILLER_WORDS.has(w));
const hasAskPhrase = (text) => {
  const folded = words(text).join(' ');
  return ASK_PHRASES.some((phrase) => folded.includes(phrase));
};

/** Czy fraza zaczyna się od słowa pytającego (po wypełniaczach i jednym przyimku). */
function opensQuestion(clause) {
  let all = words(clause);
  for (;;) {
    // „Nie, po prostu jakie featury…" - „po" otwiera też „po co", więc
    // „po prostu" zdejmujemy jako parę.
    if (all[0] === 'po' && all[1] === 'prostu') all = all.slice(2);
    else if (all.length && FILLER_WORDS.has(all[0]) && !ALL_OPENERS.some((o) => o[0] === all[0])) all = all.slice(1);
    else break;
  }
  if (!all.length) return false;
  const starts = LEADING_PARTICLES.has(all[0]) ? [all, all.slice(1)] : [all];
  return starts.some((ws) => ws.length > 0 && ALL_OPENERS.some((parts) => parts.every((part, i) => ws[i] === part)));
}

/**
 * Frazy zdania razem z miejscem, w którym zaczynają się w tekście, żeby
 * pytanie wyciąć z oryginału, a nie skleić na nowo.
 */
function clausesOf(sentence) {
  const out = [];
  let start = 0;
  for (let i = 0; i <= sentence.length; i++) {
    if (i === sentence.length || sentence[i] === ',' || sentence[i] === ';') {
      const text = sentence.slice(start, i).trim();
      if (text) out.push({ text, start });
      start = i + 1;
    }
  }
  return out;
}

/**
 * Ocena jednego zdania.
 *
 * Słowo pytające liczy się tylko na początku zdania: po wypełniaczach
 * („Okej, dobra, a jak…") albo po wstępie („mam pytanie, czym…",
 * „powiedz mi, ile…"). Po zwykłej frazie to prawie zawsze zaimek względny
 * albo spójnik: „Podobało mi się, jak zrobiłeś", „praca, która była",
 * „godzin, czy tam estymacja". Właśnie to dawało najwięcej fałszywych trafień.
 */
function scoreSentence(sentence) {
  const clauses = clausesOf(sentence.text);
  const first = clauses.findIndex((c) => !isFillerClause(c.text));
  let head = first;
  let opener = false;
  for (let k = Math.max(first, 0); k < clauses.length; k++) {
    const atStart = k === first;
    const afterLead = k > 0 && (isFillerClause(clauses[k - 1].text) || hasAskPhrase(clauses[k - 1].text));
    if (!atStart && !afterLead) continue;
    if (opensQuestion(clauses[k].text)) {
      opener = true;
      // „Opowiedz mi o projekcie, czym się tam zajmowałeś" - polecenie przed
      // słowem pytającym niesie treść (o który projekt chodzi), więc pytanie
      // zaczyna się od niego. Sam wstęp („mam pytanie, czym…") nie.
      head = k > 0 && !isFillerClause(clauses[k - 1].text) && hasAskPhrase(clauses[k - 1].text) ? k - 1 : k;
      break;
    }
  }

  const asked = sentence.end === '?';
  const lastWords = clauses.length > 1 ? words(clauses[clauses.length - 1].text).join(' ') : '';
  const confirmation = asked && !opener && CONFIRMATION_TAGS.has(lastWords);
  const phrase = hasAskPhrase(sentence.text);

  let confidence = 0;
  const reasons = [];
  if (asked) {
    confidence += confirmation ? 0.25 : 0.6;
    reasons.push(confirmation ? 'potwierdzenie' : 'pytajnik');
  }
  if (opener) {
    // Kropka albo wykrzyknik od ASR to sygnał, że zdanie jest oznajmujące
    // („A co dalej będzie, to nie wiadomo."), a wielokropek, że urwane.
    // Pełną wagę słowo pytające ma tylko bez interpunkcji (napisy Meet)
    // albo razem z pytajnikiem.
    confidence += asked || sentence.end === '' ? 0.4 : 0.2;
    reasons.push('słowo-pytające');
    if (sentence.end === '.' && words(sentence.text).some(isSecondPerson)) {
      confidence += 0.2;
      reasons.push('do-rozmówcy');
    }
  }
  if (phrase) {
    confidence += 0.4;
    reasons.push('zwrot-pytający');
  }
  return {
    confidence: Math.min(1, Math.round(confidence * 100) / 100),
    reasons,
    start: head >= 0 ? clauses[head].start : 0,
  };
}

/**
 * Czy wypowiedź zawiera pytanie wymagające odpowiedzi merytorycznej.
 *
 * Oceniamy każde zdanie osobno i bierzemy najlepsze. Do modelu idzie samo
 * pytanie: od jego początku (bez wstępu i bez tego, co padło przed nim) do
 * końca serii pytań, które po sobie następują („Rok? Dwa?").
 * @returns {{isQuestion: boolean, confidence: number, reason: string, question: string}}
 */
export function detectQuestion(text) {
  const raw = stripHallucinations(text);
  const folded = fold(raw);
  const allWords = folded ? folded.split(' ') : [];

  const no = (reason) => ({ isQuestion: false, confidence: 0, reason, question: '' });

  if (raw.length < MIN_QUESTION_CHARS || allWords.length < MIN_QUESTION_WORDS) return no('za-krótkie');
  if (SMALL_TALK_PATTERNS.some((pattern) => pattern.test(folded))) return no('small-talk');

  const sentences = splitSentences(raw);
  const scored = sentences.map(scoreSentence);
  let best = 0;
  scored.forEach((s, i) => { if (s.confidence > scored[best].confidence) best = i; });
  const top = scored[best];
  if (!top || top.confidence < 0.35) {
    return { isQuestion: false, confidence: top?.confidence ?? 0, reason: top?.reasons.join('+') || 'brak-sygnałów', question: '' };
  }

  // Seria pytań wokół najlepszego: „Czekaj, czyli swipe nie usuwa nawyku?
  // To gdzie jest usuwanie?" - pierwsze daje drugiemu sens. Wstecz bierzemy
  // też potwierdzenia („…, której nie ma w CV, tak? Czy ona gdzieś jest?"):
  // same nie są pytaniem, ale bez nich „czy ona gdzieś jest" nic nie znaczy.
  let from = best;
  while (from > 0 && (scored[from - 1].confidence >= 0.35 || sentences[from - 1].end === '?')) from--;
  let to = best;
  while (to + 1 < sentences.length && sentences[to + 1].end === '?' && scored[to + 1].confidence >= 0.35) to++;

  const render = (a, b) => sentences.slice(a, b + 1)
    .map((s, i) => {
      const body = i === 0 ? s.text.slice(scored[a].start).trim() : s.text;
      return body + (s.end === '…' ? '…' : s.end);
    })
    .join(' ');
  if (from > 0 && render(from, to).length < MIN_STANDALONE_CHARS) {
    from--;
    scored[from] = { ...scored[from], start: 0 };
  }
  let question = render(from, to);
  if (question.length > MAX_QUESTION_CHARS) question = render(best, best);
  if (question.length > MAX_QUESTION_CHARS) question = `${question.slice(0, MAX_QUESTION_CHARS - 1)}…`;

  return { isQuestion: true, confidence: top.confidence, reason: top.reasons.join('+'), question };
}

/**
 * Okno transkryptu w prompcie. Było 6 wypowiedzi / 1200 znaków i przy
 * „masz jakieś pytania?" model dopytywał o to, co padło 15 minut wcześniej
 * (zdalna praca, branża, długość projektu). 4000 znaków to ~1000 tokenów:
 * zmierzone 2026-10-06 na Sonnecie: TTFT 0,9 s -> 2,0 s w medianie, ale
 * pytania do zadania przestały powtarzać to, co rekruter już powiedział.
 */
const DEFAULT_CONTEXT_SEGMENTS = 30;
const MAX_CONTEXT_CHARS = 4000;
/** Twardy limit kontekstu projektu — dłuższy opis to wolniejsza odpowiedź. */
const MAX_PROJECT_CONTEXT_CHARS = 8000;

/**
 * Buduje prompt: pytanie + minimalny konieczny kontekst.
 *
 * Kontekst trzymamy krótko celowo — każdy dodatkowy token to opóźnienie,
 * a odpowiedź ma paść, zanim rozmowa pójdzie dalej.
 */
export function buildPrompt({
  question,
  segments = [],
  title = '',
  projectContext = '',
  maxSegments = DEFAULT_CONTEXT_SEGMENTS,
}) {
  const asked = normalize(question);
  if (!asked) return null;

  const recent = segments
    .slice(-maxSegments)
    .map((s) => `${s.speaker}: ${normalize(s.text)}`)
    .filter((line) => line.length > 3);

  let context = recent.join('\n');
  if (context.length > MAX_CONTEXT_CHARS) {
    context = `…${context.slice(-MAX_CONTEXT_CHARS)}`;
  }

  const parts = [];
  if (title) parts.push(`Spotkanie: ${normalize(title)}`);
  // Kontekst projektu idzie przed transkryptem: to tło, na którym toczy się
  // rozmowa, a nie to, co przed chwilą padło.
  if (projectContext) {
    const trimmed = projectContext.length > MAX_PROJECT_CONTEXT_CHARS
      ? `${projectContext.slice(0, MAX_PROJECT_CONTEXT_CHARS)}…`
      : projectContext;
    parts.push(`Kontekst projektu, o którym jest rozmowa:\n${trimmed}`);
  }
  if (context) parts.push(`Ostatnie wypowiedzi:\n${context}`);
  parts.push(`Pytanie, na które masz odpowiedzieć:\n${asked}`);
  return parts.join('\n\n');
}

/** Stan pytań i odpowiedzi w trakcie rozmowy. */
export class AssistantSession {
  #items = new Map();
  #sequence = 0;

  constructor({ maxItems = 30 } = {}) {
    this.maxItems = maxItems;
    this.revision = 0;
  }

  /** @returns {{id: string, question: string, status: string}} */
  add({ question, speaker = null, at = Date.now(), auto = false }) {
    const id = `q${++this.#sequence}`;
    const item = {
      id,
      question: normalize(question),
      speaker,
      at,
      auto,
      status: 'pending',
      answer: '',
      error: null,
    };
    this.#items.set(id, item);
    this.#trim();
    this.revision++;
    return item;
  }

  append(id, delta) {
    const item = this.#items.get(id);
    if (!item) return null;
    item.answer += delta;
    item.status = 'streaming';
    this.revision++;
    return item;
  }

  complete(id, { answer = null, durationMs = null } = {}) {
    const item = this.#items.get(id);
    if (!item) return null;
    if (answer !== null) item.answer = answer;
    item.status = 'done';
    item.durationMs = durationMs;
    this.revision++;
    return item;
  }

  fail(id, error) {
    const item = this.#items.get(id);
    if (!item) return null;
    item.status = 'error';
    item.error = String(error?.message ?? error);
    this.revision++;
    return item;
  }

  get(id) {
    return this.#items.get(id) ?? null;
  }

  get items() {
    return [...this.#items.values()];
  }

  #trim() {
    while (this.#items.size > this.maxItems) {
      this.#items.delete(this.#items.keys().next().value);
    }
  }
}
