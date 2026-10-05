/**
 * Logika asystenta: co jest pytaniem i jak zbudować z transkrypcji prompt.
 *
 * Czysta i testowalna — nie wie nic o HTTP, WebSocketach ani o Claude Code.
 */

import { normalize } from './text.js';

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
  /\b(slychac|slyszysz|slyszycie|slysze|widac|widzisz|widzicie|widze)\b/,
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

/** Ile fraz doklejamy do pytania, gdy pytajnik nigdzie nie padł. */
const MAX_QUESTION_CLAUSES = 2;
/** Twardy limit długości pytania. Prompt ma być krótki, nie kompletny. */
const MAX_QUESTION_CHARS = 220;
/** Jak daleko szukamy pytajnika, zanim uznamy, że go nie ma. */
const QUESTION_LOOKAHEAD = 6;

const ALL_OPENERS = [...QUESTION_OPENERS.pl, ...QUESTION_OPENERS.en];

/**
 * Słówka, które w mowie stoją PRZED właściwym słowem pytającym.
 *
 * „A jak to wpłynie na czas budowania" i „Od której wersji jest dostępny" to
 * najzwyklejszy polski szyk, a sprawdzanie wyłącznie pierwszego słowa frazy
 * gubiło oba — bo `jak` i `ktorej` stały na drugiej pozycji. Bez pytajnika
 * (a mowa go nie zawsze daje) takie pytanie przepadało bez śladu.
 */
const LEADING_PARTICLES = new Set([
  'a', 'no', 'i', 'to', 'wiec', 'ale', 'czyli', 'oraz',
  'od', 'do', 'w', 'na', 'z', 'za', 'po', 'przy', 'dla', 'o', 'u',
]);

/** Czy fraza zaczyna się od słowa pytającego, ewentualnie po jednym słówku. */
function opensQuestion(clause) {
  const all = fold(clause).split(/\s+/).filter(Boolean);
  if (!all.length) return false;

  // Dopuszczamy najwyżej jedno słówko przed pytaniem — dwa to już zdanie,
  // a nie wtrącenie, i zaczęłoby łapać zwykłe wypowiedzi.
  const starts = LEADING_PARTICLES.has(all[0]) ? [all, all.slice(1)] : [all];
  return starts.some((words) =>
    words.length > 0 &&
    ALL_OPENERS.some((opener) => {
      const parts = fold(opener).split(' ');
      return parts.every((part, i) => words[i] === part);
    }));
}

/**
 * Czy wypowiedź wygląda na pytanie wymagające odpowiedzi merytorycznej.
 * @returns {{isQuestion: boolean, confidence: number, reason: string, question: string}}
 */
export function detectQuestion(text) {
  const raw = normalize(text);
  const folded = fold(raw);
  const words = folded ? folded.split(' ') : [];

  const no = (reason) => ({ isQuestion: false, confidence: 0, reason, question: '' });

  if (raw.length < MIN_QUESTION_CHARS || words.length < MIN_QUESTION_WORDS) return no('za-krótkie');
  if (SMALL_TALK_PATTERNS.some((pattern) => pattern.test(folded))) return no('small-talk');

  let confidence = 0;
  const reasons = [];
  const clauses = splitClauses(raw);

  if (raw.endsWith('?')) {
    confidence += 0.6;
    reasons.push('pytajnik');
  }

  // Fraza otwarta słowem pytającym — i to od niej zaczyna się właściwe pytanie.
  const openerIndex = clauses.findIndex(opensQuestion);
  if (openerIndex >= 0) {
    confidence += openerIndex === 0 ? 0.35 : 0.45;
    reasons.push(openerIndex === 0 ? 'słowo-pytające' : 'słowo-pytające-w-środku');
  }

  // Jawny zwrot („mam pytanie", „quick question") jest jednoznaczny i musi
  // wystarczyć sam — wcześniej dawał 0,3 przy progu 0,35 i przepadał.
  const phraseHit = ASK_PHRASES.find((phrase) => folded.includes(phrase));
  if (phraseHit) {
    confidence += 0.4;
    reasons.push('zwrot-pytający');
  }

  confidence = Math.min(1, confidence);

  // Do modelu wysyłamy właściwe pytanie — bez dygresji przed nim i bez tego,
  // co padło po nim. Przy długiej, niepodzielonej wypowiedzi branie wszystkiego
  // do końca wciągało do promptu odpowiedź na to samo pytanie, a prompt rósł
  // do setek znaków i odpowiedź szła 9 s zamiast 1,5 s.
  const question = openerIndex >= 0 ? extractQuestion(raw, openerIndex) : raw;

  return {
    isQuestion: confidence >= 0.35,
    confidence,
    reason: reasons.join('+') || 'brak-sygnałów',
    question,
  };
}

/**
 * Wycina pytanie zaczynające się od frazy `openerIndex`.
 *
 * Koniec wyznacza pytajnik. Gdy go nie ma (mowa często go nie daje), bierzemy
 * najwyżej `MAX_QUESTION_CLAUSES` fraz — dalej to już nie jest pytanie.
 */
function extractQuestion(raw, openerIndex) {
  const clauses = splitClausesWithEnd(raw);
  if (!clauses.length) return raw;

  // Najpierw szukamy pytajnika w rozsądnym zasięgu. Pytanie z przecinkami
  // („co się dzieje, gdy mija północ?") ma kilka fraz i ucięcie go po dwóch
  // gubi właśnie tę część, o którą chodzi.
  let end = -1;
  for (let i = openerIndex; i < clauses.length && i < openerIndex + QUESTION_LOOKAHEAD; i++) {
    if (clauses[i].endsQuestion) { end = i; break; }
  }
  // Bez pytajnika bierzemy dwie frazy — dalej to już zwykle odpowiedź,
  // która po pytaniu padła.
  if (end < 0) end = Math.min(openerIndex + MAX_QUESTION_CLAUSES - 1, clauses.length - 1);

  const joined = clauses.slice(openerIndex, end + 1).map((c) => c.text).join(', ');
  return joined.length > MAX_QUESTION_CHARS ? `${joined.slice(0, MAX_QUESTION_CHARS - 1)}…` : joined;
}

const DEFAULT_CONTEXT_SEGMENTS = 6;
const MAX_CONTEXT_CHARS = 1200;
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
