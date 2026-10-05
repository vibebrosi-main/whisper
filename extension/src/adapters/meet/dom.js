/**
 * Odczyt napisów Google Meet z DOM.
 *
 * Meet mieli klasy CSS co kilka tygodni, więc nie opieramy się na nich jako na
 * jedynym źródle prawdy. Znane atrybuty (`jsname`) i klasy traktujemy jako
 * *podpowiedzi*, a jeśli ich zabraknie — rozpoznajemy blok napisów po
 * strukturze: awatar/krótka etykieta z nazwiskiem + dłuższy blok tekstu.
 *
 * Moduł celowo używa wyłącznie `children` / `textContent` / `getAttribute` /
 * `tagName`, dzięki czemu da się go testować na atrapie DOM bez jsdom.
 */

import { normalize } from '../../core/text.js';

/** `jsname` bloku pojedynczego mówcy. */
export const BLOCK_JSNAME = 'dsyhDe';
/** `jsname` kontenera z samym tekstem wypowiedzi. */
export const TEXT_JSNAME = 'tgaKEf';
/** Fragmenty klas, które historycznie oznaczały nazwę mówcy. */
export const NAME_CLASS_HINTS = ['zs7s8d', 'KcIKyf'];
/** Kandydaci na kontener napisów, od najbardziej do najmniej pewnego. */
export const ROOT_SELECTORS = ['.a4cQT', '[aria-live="polite"]', '[aria-live="assertive"]'];

const MAX_WALK_DEPTH = 10;
const MAX_NAME_LENGTH = 64;
const MAX_NAME_WORDS = 7;

const tagOf = (el) => String(el?.tagName ?? '').toUpperCase();
const attrOf = (el, name) => (typeof el?.getAttribute === 'function' ? el.getAttribute(name) : null) ?? '';

function childElements(el) {
  const kids = el?.children;
  if (!kids) return [];
  return Array.from(kids);
}

/** Czy tekst wygląda na etykietę z imieniem, a nie na wypowiedź. */
export function isNameLike(text) {
  const t = normalize(text);
  if (!t || t.length > MAX_NAME_LENGTH) return false;
  if (t.split(' ').length > MAX_NAME_WORDS) return false;
  return !/[.!?]$/.test(t);
}

/**
 * Zbiera liście tekstowe poddrzewa wraz z kontekstem
 * (czy są w regionie nazwy, czy w regionie tekstu, czy sąsiadują z avatarem).
 */
export function collectLeaves(el, ctx = { name: false, text: false, nearImage: false }, out = [], depth = 0) {
  if (!el || depth > MAX_WALK_DEPTH) return out;

  const cls = attrOf(el, 'class');
  const jsname = attrOf(el, 'jsname');
  const next = {
    name: ctx.name || NAME_CLASS_HINTS.some((hint) => cls.includes(hint)),
    text: ctx.text || jsname === TEXT_JSNAME,
    nearImage: ctx.nearImage,
  };

  const kids = childElements(el);
  if (!kids.length) {
    const text = normalize(el.textContent);
    if (text) out.push({ el, text, name: next.name, isText: next.text, nearImage: next.nearImage });
    return out;
  }

  const hasImage = kids.some((k) => tagOf(k) === 'IMG');
  for (const kid of kids) {
    if (tagOf(kid) === 'IMG') continue;
    collectLeaves(kid, { ...next, nearImage: next.nearImage || hasImage }, out, depth + 1);
  }
  return out;
}

/**
 * Parsuje pojedynczy blok napisów.
 * @returns {{speaker: string|null, text: string}|null}
 */
export function parseBlock(el) {
  const leaves = collectLeaves(el);
  if (!leaves.length) return null;

  const textLeaves = leaves.filter((l) => l.isText);
  let nameLeaf =
    leaves.find((l) => l.name && !l.isText) ??
    leaves.find((l) => l.nearImage && !l.isText && isNameLike(l.text)) ??
    null;

  let bodyLeaves;
  if (textLeaves.length) {
    bodyLeaves = textLeaves;
    if (!nameLeaf) nameLeaf = leaves.find((l) => !l.isText && isNameLike(l.text)) ?? null;
  } else {
    if (!nameLeaf) {
      // Bez podpowiedzi: pierwszy krótki liść to nazwa, reszta to wypowiedź.
      if (leaves.length < 2 || !isNameLike(leaves[0].text)) return null;
      nameLeaf = leaves[0];
    }
    bodyLeaves = leaves.filter((l) => l !== nameLeaf);
  }

  const text = normalize(bodyLeaves.map((l) => l.text).join(' '));
  if (!text) return null;

  const speaker = normalize(nameLeaf?.text ?? '');
  return { speaker: speaker || null, text };
}

function isBlockLike(el) {
  return parseBlock(el) !== null;
}

/** Najgłębsze elementy, które parsują się jako blok napisów. */
export function walkForBlocks(el, depth = 0, out = []) {
  if (!el || depth > MAX_WALK_DEPTH) return out;
  const before = out.length;
  for (const kid of childElements(el)) walkForBlocks(kid, depth + 1, out);
  if (out.length === before && isBlockLike(el)) out.push(el);
  return out;
}

/** Bloki mówców wewnątrz kontenera napisów. */
export function collectBlocks(root) {
  if (!root) return [];
  if (typeof root.querySelectorAll === 'function') {
    const marked = Array.from(root.querySelectorAll(`[jsname="${BLOCK_JSNAME}"]`));
    if (marked.length) return marked;
  }
  return walkForBlocks(root);
}

function ancestorChain(el) {
  const out = [];
  let current = el?.parentElement;
  while (current) {
    out.push(current);
    current = current.parentElement;
  }
  return out;
}

/** Czy `el` leży w poddrzewie `root` (działa też na atrapie DOM). */
export function containsNode(root, el) {
  if (!root || !el) return false;
  return root === el || ancestorChain(el).includes(root);
}

/**
 * Najbliższy wspólny przodek elementów.
 * Bierzemy go zamiast `parentElement` pierwszego bloku, bo gdyby Meet owinął
 * każdego mówcę osobnym kontenerem, obserwowalibyśmy tylko jednego z nich.
 */
export function commonAncestor(elements) {
  const list = Array.from(elements ?? []);
  if (!list.length) return null;
  if (list.length === 1) return list[0].parentElement ?? list[0];

  const chain = ancestorChain(list[0]);
  const others = list.slice(1).map((el) => new Set(ancestorChain(el)));
  return chain.find((node) => others.every((set) => set.has(node))) ?? null;
}

/** Kontener napisów, albo null gdy napisy są wyłączone. */
export function findCaptionRoot(doc) {
  if (!doc) return null;
  const marked = Array.from(doc.querySelectorAll?.(`[jsname="${BLOCK_JSNAME}"]`) ?? []);
  if (marked.length) {
    const root = commonAncestor(marked);
    if (root) return root;
  }

  for (const selector of ROOT_SELECTORS) {
    for (const candidate of Array.from(doc.querySelectorAll?.(selector) ?? [])) {
      if (collectBlocks(candidate).length) return candidate;
    }
  }
  return null;
}

const CAPTION_LABEL = /(caption|subtitle|napis|untertitel|sous-titre|subt[íi]tul|字幕|subtitr)/i;
const OFF_LABEL = /(turn off|disable|wy[łl][ąa]cz|desactiv|deaktiv|d[ée]sactiv|off\b)/i;

/** Przycisk włączania/wyłączania napisów (dowolny język UI). */
export function findCaptionsButton(doc) {
  const nodes = Array.from(doc?.querySelectorAll?.('button[aria-label], [role="button"][aria-label]') ?? []);
  for (const node of nodes) {
    const label = attrOf(node, 'aria-label');
    if (CAPTION_LABEL.test(label)) return node;
  }
  return null;
}

/** 'on' | 'off' | 'unknown' — wywnioskowane z etykiety/aria-pressed przycisku. */
export function captionsState(doc) {
  const button = findCaptionsButton(doc);
  if (!button) return 'unknown';
  const pressed = attrOf(button, 'aria-pressed');
  if (pressed === 'true') return 'on';
  if (pressed === 'false') return 'off';
  const label = attrOf(button, 'aria-label');
  return OFF_LABEL.test(label) ? 'on' : 'off';
}

/** Kod spotkania z URL-a: https://meet.google.com/abc-defg-hij */
export function meetingCode(url) {
  const match = /meet\.google\.com\/([a-z]{3}-[a-z]{4}-[a-z]{3})/i.exec(String(url ?? ''));
  return match ? match[1] : '';
}

/** Nazwa spotkania — z tytułu dokumentu, z fallbackiem na kod. */
export function meetingTitle(doc, url) {
  const raw = normalize(doc?.title ?? '').replace(/\s*[-–—]\s*Google Meet\s*$/i, '');
  const code = meetingCode(url);
  if (raw && raw.toLowerCase() !== 'meet' && raw !== code) return raw;
  return code ? `Google Meet ${code}` : 'Google Meet';
}
