/**
 * Generuje wektory referencyjne z implementacji JS.
 *
 * Port na Swift ma dawać te same liczby co wersja webowa — inaczej pliki .md
 * z obu wersji różniłyby się, a diaryzacja rozjechałaby się po cichu. Zamiast
 * przepisywać asercje ręcznie, bierzemy je z działającego kodu.
 *
 *   node macos/tools/gen-fixtures.mjs
 */
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { normalize, reconcile, wordCount, truncate } from '../../extension/src/core/text.js';
import { formatOffset, formatDuration } from '../../extension/src/core/time.js';
import { detectQuestion, buildPrompt, fold, splitClauses } from '../../extension/src/core/assistant.js';
import { renderMarkdown } from '../../extension/src/core/markdown.js';
import { TranscriptStore } from '../../extension/src/core/transcript.js';
import { MfccExtractor } from '../../extension/src/adapters/audio/features.js';
import { Vad } from '../../extension/src/adapters/audio/vad.js';
import { Diarizer, embedFrames, l2Normalize, cosineSimilarity } from '../../extension/src/adapters/audio/diarizer.js';
import { AudioRing } from '../../extension/src/adapters/audio/ring.js';
import { encodeWav } from '../../extension/src/adapters/audio/wav.js';
import { cleanText } from '../../extension/src/adapters/audio/whisper-local.js';

const SR = 16_000, FRAME = 400, HOP = 160;

function noise(seed) {
  let state = seed;
  return () => {
    state = (state * 1103515245 + 12345) % 2147483648;
    return state / 2147483648 - 0.5;
  };
}

function voice({ f0, formants, seconds, gain = 1, seed = 7 }) {
  const random = noise(seed);
  const length = Math.round(seconds * SR);
  const out = new Float64Array(length);
  for (let i = 0; i < length; i++) {
    const t = i / SR;
    const envelope = 0.7 + 0.3 * Math.sin(2 * Math.PI * 4 * t);
    let value = 0.4 * Math.sin(2 * Math.PI * f0 * t);
    for (const [freq, amp] of formants) value += amp * Math.sin(2 * Math.PI * freq * t + freq);
    out[i] = gain * envelope * value + 0.004 * random();
  }
  return out;
}

function silence(seconds, seed = 3) {
  const random = noise(seed);
  const out = new Float64Array(Math.round(seconds * SR));
  for (let i = 0; i < out.length; i++) out[i] = 0.0015 * random();
  return out;
}

function concat(chunks) {
  const total = chunks.reduce((a, c) => a + c.length, 0);
  const out = new Float64Array(total);
  let off = 0;
  for (const c of chunks) { out.set(c, off); off += c.length; }
  return out;
}

const ANNA = { f0: 205, formants: [[520, 0.30], [2350, 0.26], [3100, 0.12]] };
const JAN = { f0: 105, formants: [[330, 0.32], [1100, 0.24], [2400, 0.10]] };

// ---------- tekst ----------
const reconcileCases = [
  ['', 'Cześć wszystkim'],
  ['Cześć wszystkim', 'Cześć wszystkim, zaczynamy'],
  ['Cześć wszystkim zaczynamy stand', 'Cześć wszystkim zaczynamy standup'],
  ['ala ma kota a kot ma', 'kota a kot ma ale'],
  ['zupełnie inny tekst', 'nic wspólnego tutaj'],
  ['Mamy snapshoty co godzinę', 'Mamy snapshoty co godzinę'],
  ['abc', 'abcdef'],
  ['jeden dwa trzy cztery', 'jeden dwa trzy'],
].map(([a, b]) => ({ prev: a, next: b, result: reconcile(a, b) }));

const normalizeCases = [
  '  wiele   spacji  ',
  'zero​szerokości',
  'nowa\nlinia\ti tab',
  '',
].map((input) => ({ input, result: normalize(input) }));

const foldCases = ['Słychać', 'CZY KTOŚ WIE', 'żółć gęś', 'Łódź'].map((input) => ({ input, result: fold(input) }));

const wordCountCases = ['ala ma kota', '', '   jeden   '].map((input) => ({ input, result: wordCount(input) }));
const truncateCases = [['bardzo długi tekst do ucięcia', 10]].map(([t, m]) => ({ input: t, max: m, result: truncate(t, m) }));

// ---------- czas ----------
const offsetCases = [0, 4000, 71_000, 3_661_000, -500].map((ms) => ({ ms, result: formatOffset(ms) }));
const durationCases = [0, 8000, 2_531_000, 3_732_000].map((ms) => ({ ms, result: formatDuration(ms) }));

// ---------- pytania ----------
const questionCases = [
  'A jakie RPO i RTO to nam daje?',
  'Wracając do migracji, mam pytanie, czym różni się RPO od RTO',
  'czy mnie słychać',
  'no dobra',
  'Czy ktoś wie ile to kosztuje',
  'widzicie mój ekran',
  'Ile mamy czasu do końca sprintu',
  'Halo halo',
  'Zastanawiam się nad polityką backupów',
  'What does this endpoint return',
  // Szyk z wtrąceniem przed słowem pytającym — bez pytajnika, jak w mowie.
  'Od której wersji API dostępny jest Predictive Back',
  'A jak to wpłynie na czas budowania w Gradle',
  'Czy ktoś wie jak dokładnie działa remember w Compose',
  'A potem wrócimy do listy transakcji',
  'No i tyle w tym temacie',
  // Pytanie sklejone z odpowiedzią — tak wygląda długi, niepodzielony segment.
  'Shared Flow do zdarzeń jednorazowych, takich jak nawigacja. Wracając do listy mam pytanie, czy LazyColumn recyklinguje elementy tak samo jak RecyclerView? Nie do końca tak samo, ale efekt jest podobny.',
  'Dobra. Teraz o wydajności. Czy ktoś wie, jak dokładnie działa remember w Compose? Remember zapamiętuje wartość w slocie kompozycji.',
  // Pytanie z przecinkami: pytajnik pada dopiero w trzeciej frazie.
  'Dobra, a teraz coś trudniejszego. Czy ktoś wie, co się dzieje ze statusem wykonania, gdy aplikacja stoi w tle przez całą noc i mija północ?',
  'Czekaj, czyli swipe nie usuwa nawyku? To gdzie jest usuwanie i czy jest potwierdzenie?',
  // Regresje z rozmowy kwalifikacyjnej: zaimki względne, kropka, potwierdzenia.
  'Podobało mi się, jak zrobiłeś. Kiedy będę miał parę pytań bardziej do Ciebie, takich ogólnych.',
  'Raportowanie godzin, czy tam estymacja zadań będzie również na ClickUpie.',
  'trzy miesiące. na takim pełen metacie. A co dalej będzie, to nie wiadomo. Plany są jakby na rozwój.',
  'To jeżeli miałbyś tak określić, na przykład, ile już...',
  'Mieliś doświadczenie, designerem byłeś tylko, tak?',
  'Okej, no bo mówisz o tej firmie na pełnym etacie, której nie ma w CV, tak? W sensie, czy ona gdzieś jest?',
  'Dobra. Fajnie. Dobra, a powiedz mi, jak długo programujesz? Bo tam widziałem, że na początku',
  'Okej, a jak twoja praca wyglądała jako pełen etat? I jakie to były firmy? I jak to był podział? Bo ciągle mówisz.',
  'Dziękuje za uwagę. Okej, ale to byś poszył jakby oddzielny komponent do tego, na jednym byś to wszystko zrobił?',
  'Pracowałeś firmy jako frontendowiec o full stack, to ile to będzie lat? Rok? Dwa?',
  'Używasz Next.js czy Node.js do backendu?',
  'Okej, ale... od node\'a jakieś frameworki, na przykład Next.js, Hono, czy też nie?',
].map((text) => {
  const v = detectQuestion(text);
  return { text, isQuestion: v.isQuestion, confidence: v.confidence, reason: v.reason, question: v.question };
});

const clauseCases = ['Wracając do migracji, mam pytanie, czym różni się RPO od RTO']
  .map((text) => ({ text, result: splitClauses(text) }));

// ---------- markdown ----------
const startedAt = Date.UTC(2026, 7, 23, 8, 15, 3);
const mdSession = {
  meta: { title: 'Standup zespołu', source: 'google-meet', url: 'https://meet.google.com/abc-defg-hij', startedAt, endedAt: startedAt + 2_531_000 },
  segments: [
    { id: 's1', speaker: 'Anna Kowalska', text: 'Cześć wszystkim, zaczynamy standup.', startedAt: startedAt + 4000, endedAt: startedAt + 9000, offsetMs: 4000, final: true },
    { id: 's2', speaker: 'Jan Nowak', text: 'Hej, słychać mnie? Mam *gwiazdkę* i _podkreślenie_.', startedAt: startedAt + 11_000, endedAt: startedAt + 14_000, offsetMs: 11_000, final: true },
    { id: 's3', speaker: 'Anna Kowalska', text: 'Lecimy dalej.', startedAt: startedAt + 20_000, endedAt: startedAt + 22_000, offsetMs: 20_000, final: false },
  ],
};
// Renderujemy bez frontmattera i bez dat lokalnych zależnych od strefy — samą
// treść, żeby fixture nie zależał od TZ maszyny.
const markdown = renderMarkdown(mdSession, { frontmatter: false, locale: 'pl' });
const markdownEn = renderMarkdown(mdSession, { frontmatter: false, locale: 'en', stats: false });

// ---------- transkrypt ----------
const t0 = 1_700_000_000_000;
const store = new TranscriptStore({ startedAt: t0, silenceMs: 2500 });
store.upsert({ key: 'a', speaker: 'Anna', text: 'Cześć', at: t0 + 100 });
store.upsert({ key: 'a', speaker: 'Anna', text: 'Cześć wszystkim', at: t0 + 400 });
store.upsert({ key: 'b', speaker: 'Jan', text: 'Hej', at: t0 + 900 });
store.finalizeIdle(t0 + 5000);
store.upsert({ key: 'c', speaker: 'Anna', text: 'Druga wypowiedź Anny', at: t0 + 30_000 });
store.finalizeAll(t0 + 40_000);
const transcriptResult = store.segments.map((s) => ({ speaker: s.speaker, text: s.text, offsetMs: s.offsetMs, final: s.final }));

// ---------- MFCC ----------
const extractor = new MfccExtractor();
const annaSignal = voice({ ...ANNA, seconds: 0.2 });
const mfccFrames = [];
for (let i = 0; i < 3; i++) {
  const start = i * HOP;
  mfccFrames.push([...extractor.frameToMfcc(annaSignal.subarray(start, start + FRAME))]);
}
const energyDb = [0, 1, 2].map((i) => MfccExtractor.frameEnergyDb(annaSignal.subarray(i * HOP, i * HOP + FRAME)));

// ---------- VAD ----------
const vadSignal = concat([silence(0.4), voice({ ...ANNA, seconds: 0.8 }), silence(0.6)]);
const vad = new Vad();
const vadEvents = [];
for (let start = 0; start + FRAME <= vadSignal.length; start += HOP) {
  const db = MfccExtractor.frameEnergyDb(vadSignal.subarray(start, start + FRAME));
  const s = vad.push(db);
  if (s.started) vadEvents.push({ event: 'start', frame: start / HOP });
  if (s.ended) vadEvents.push({ event: 'end', frame: start / HOP });
}

// ---------- diaryzacja ----------
const diarSignal = concat([
  silence(0.3),
  voice({ ...ANNA, seconds: 1.2, seed: 11 }),
  silence(0.5),
  voice({ ...JAN, seconds: 1.2, seed: 13 }),
  silence(0.5),
  voice({ ...ANNA, seconds: 1.2, seed: 17 }),
  silence(0.4),
]);
const diarizer = new Diarizer();
for (let start = 0; start + FRAME <= diarSignal.length; start += HOP) {
  diarizer.pushFrame(diarSignal.subarray(start, start + FRAME), (start / SR) * 1000);
}
diarizer.flush((diarSignal.length / SR) * 1000);
const turns = diarizer.turns.map((t) => ({ speaker: t.speaker, startMs: Math.round(t.startMs), endMs: Math.round(t.endMs) }));

// ---------- embedding ----------
const embA = [...embedFrames(mfccFrames.map((f) => Float64Array.from(f)))];
const norm34 = [...l2Normalize(Float64Array.from([3, 4]))];

// ---------- prompt ----------
const prompt = buildPrompt({
  question: 'A jakie RPO i RTO to nam daje?',
  segments: mdSession.segments,
  title: 'Standup zespołu',
});

// ---------- bufor kołowy ----------
const ring = new AudioRing({ sampleRate: 1000, seconds: 1, epochMs: 0 }); // 1000 próbek
ring.write(Float32Array.from({ length: 600 }, (_, i) => i / 1000));
const ringA = [...(ring.readRange(100, 300) ?? [])];
ring.write(Float32Array.from({ length: 600 }, (_, i) => (600 + i) / 1000));
// bufor się zawinął: najstarsze 200 próbek wypadło
const ringB = [...(ring.readRange(0, 400) ?? [])];
const ringMeta = {
  oldestMs: ring.oldestMs,
  newestMs: ring.newestMs,
  written: ring.writtenSamples,
  outOfRange: ring.readRange(2000, 2500) === null,
  inverted: ring.readRange(300, 300) === null,
};

// ---------- WAV ----------
const wavSamples = Float32Array.from([0, 0.5, -0.5, 1, -1, 0.25]);
const wavBytes = [...new Uint8Array(encodeWav(wavSamples, { sampleRate: 16000 }))];

// ---------- czyszczenie tekstu whispera ----------
const cleanCases = [
  ' Zastanawiamy się nad polityką backupów.\n Mamy snapshoty.\n',
  '[BLANK_AUDIO]',
  'tekst [Muzyka] dalej (szum) koniec',
  '  wiele   spacji  ',
  // Halucynacje whispera na ciszy (prawdziwe wyjście z rozmowy 2026-09-23).
  ' Dziękuje za uwagę. Okej, a powiedz mi, jakbyś to zrobił?',
  'Zdjękuje za oglądanie! A z jakich menedżerów stanu korzystałeś?',
  'Dziękuję za uwagę.',
].map((input) => ({ input, result: cleanText(input) }));

const out = {
  note: 'Wygenerowane przez macos/tools/gen-fixtures.mjs z implementacji JS. Nie edytuj ręcznie.',
  reconcileCases, normalizeCases, foldCases, wordCountCases, truncateCases,
  offsetCases, durationCases,
  questionCases, clauseCases,
  markdown, markdownEn,
  transcriptResult,
  mfccFrames, energyDb,
  vadEvents,
  turns, speakerCount: diarizer.speakerCount,
  embA, norm34,
  prompt,
  ringA, ringB, ringMeta, wavBytes, cleanCases,
};

const here = dirname(fileURLToPath(import.meta.url));
const target = join(here, '..', 'Tests', 'CallWhisperCoreTests', 'fixtures.json');
writeFileSync(target, JSON.stringify(out, null, 2) + '\n');
console.log(`zapisano ${target}`);
console.log(`  mówców: ${diarizer.speakerCount}, tur: ${turns.length} -> ${turns.map((t) => t.speaker).join(',')}`);
console.log(`  VAD: ${vadEvents.map((e) => e.event + '@' + e.frame).join(' ')}`);
