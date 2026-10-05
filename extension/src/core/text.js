/**
 * Scalanie strumieniowego tekstu z napisów na żywo.
 *
 * Silniki napisów (Meet, Zoom, Web Speech API) aktualizują ten sam blok tekstu
 * w miejscu: tekst rośnie, bywa poprawiany, a czasem przycinany od początku
 * (przewijane okno). `reconcile` sprowadza kolejne migawki do jednego,
 * niezduplikowanego zdania.
 */

const ZERO_WIDTH = /[\u200B-\u200D\uFEFF\u00AD]/g;
const WS = /\s+/g;

/** Normalizacja białych znaków + usunięcie znaków zerowej szerokości. */
export function normalize(input) {
  if (input == null) return '';
  return String(input).replace(ZERO_WIDTH, '').replace(WS, ' ').trim();
}

/** Długość wspólnego prefiksu dwóch napisów. */
export function commonPrefixLength(a, b) {
  const max = Math.min(a.length, b.length);
  let i = 0;
  while (i < max && a.charCodeAt(i) === b.charCodeAt(i)) i++;
  return i;
}

/**
 * Najdłuższy sufiks `a`, który jest prefiksem `b`.
 * Okno ograniczone do `limit` znaków — chroni przed O(n^2) na długich blokach.
 */
export function overlapLength(a, b, limit = 240) {
  const max = Math.min(a.length, b.length, limit);
  for (let k = max; k > 0; k--) {
    if (a.endsWith(b.slice(0, k))) return k;
  }
  return 0;
}

/** Minimalna liczba znaków nakładki, przy której ufamy sklejeniu. */
const MIN_OVERLAP = 6;
/** Minimalny wspólny prefiks, przy którym uznajemy migawkę za poprawkę. */
const MIN_REVISION_PREFIX = 12;

/**
 * Łączy poprzedni stan segmentu z nową migawką tekstu.
 * Zwraca tekst wynikowy (zawsze znormalizowany).
 */
export function reconcile(prev, next) {
  const a = normalize(prev);
  const b = normalize(next);
  if (!a) return b;
  if (!b) return a;
  if (a === b) return a;

  // 1. Wzrost strumienia: nowa migawka to stara + ogon.
  if (b.startsWith(a)) return b;

  // 2. Poprawka in-place: wspólny początek, zmieniona końcówka.
  const cp = commonPrefixLength(a, b);
  if (cp >= MIN_REVISION_PREFIX || (a.length > 0 && cp >= a.length * 0.6)) {
    return b.length >= a.length ? b : a;
  }

  // 3. Przewijane okno: koniec starego = początek nowego.
  const k = overlapLength(a, b);
  if (k >= MIN_OVERLAP) return a + b.slice(k);

  // 4. Zawieranie — nic nowego albo pełne rozszerzenie.
  if (a.includes(b)) return a;
  if (b.includes(a)) return b;

  // 5. Rozłączne fragmenty tej samej wypowiedzi — doklejamy.
  return `${a} ${b}`;
}

/** Zgrubna liczba słów (do heurystyk i statystyk). */
export function wordCount(text) {
  const t = normalize(text);
  return t ? t.split(' ').length : 0;
}

/** Ucina tekst do `max` znaków, dodając wielokropek. */
export function truncate(text, max = 120) {
  const t = normalize(text);
  return t.length <= max ? t : `${t.slice(0, max - 1)}…`;
}
