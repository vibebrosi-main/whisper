/** Ustawienia użytkownika + cienka warstwa nad chrome.storage.local. */

export const SETTINGS_KEY = 'cw:settings';

export const DEFAULT_SETTINGS = {
  /** Startuj nagrywanie automatycznie po wejściu na rozmowę. */
  autoStart: true,
  /** Sam włącz napisy w Meecie, jeśli są wyłączone (bez nich nie ma transkrypcji). */
  autoEnableCaptions: true,
  /** Zapisz plik .md automatycznie po zakończeniu rozmowy. */
  autoSaveOnEnd: true,
  /** Język nagłówków w Markdownie: 'pl' | 'en'. */
  locale: 'pl',
  /** Timestampy jako godzina zegarowa zamiast offsetu od startu. */
  absoluteTimestamps: false,
  /** Blok YAML na początku pliku (Obsidian, Logseq). */
  frontmatter: true,
  /** Tabela z podziałem czasu mówienia. */
  stats: true,
  /** Ile ms bez zmiany tekstu domyka wypowiedź. */
  silenceMs: 2500,
  /** Do jakiej przerwy sklejać kolejne wypowiedzi tej samej osoby. */
  mergeGapMs: 2500,

  /* --- tryb audio --- */
  /** Domyślny tryb: 'meet' (napisy z DOM) albo 'audio' (rozpoznawanie po głosie). */
  mode: 'meet',
  /** Język rozpoznawania mowy, tag BCP-47. */
  audioLang: 'pl-PL',
  /** Czy w trybie audio przechwytywać także mikrofon. */
  captureMic: true,
  /**
   * Zgoda na rozpoznawanie w chmurze Google, gdy brakuje modelu lokalnego.
   * Domyślnie wyłączone — audio opuszczałoby wtedy urządzenie.
   */
  allowCloudSpeech: false,

  /** Silnik rozpoznawania w trybie audio: 'webspeech' (lokalnie) albo 'groq'. */
  speechBackend: 'webspeech',
  /** Klucz do Groq Speech-to-Text. Pusty = backend niedostępny. */
  groqApiKey: '',
  /** Model Whispera na Groqu. */
  groqModel: 'whisper-large-v3-turbo',
  /** Adres lokalnego whisper.cpp (npm run whisper). */
  whisperUrl: 'http://127.0.0.1:8899',

  /* --- asystent --- */
  /** Podpowiedzi Claude'a do pytań padających w rozmowie. */
  assistantEnabled: false,
  /** Adres lokalnego mostu (npm run assistant). */
  bridgeUrl: 'http://127.0.0.1:8787',
  /** Opcjonalny token mostu. */
  bridgeToken: '',
  /**
   * Pytaj automatycznie po wykryciu pytania.
   *
   * Domyślnie włączone, bo to jedyny sposób na odczuwalną szybkość: proces
   * stygnie między turami, więc pytanie musi ruszyć w momencie wykrycia,
   * a nie gdy ktoś kliknie.
   */
  assistantAutoAsk: true,
};

export const SPEECH_BACKENDS = ['webspeech', 'groq', 'whisper-local'];

export const MODES = ['meet', 'audio'];

const NUMERIC = new Set(['silenceMs', 'mergeGapMs']);

/** Odsiewa nieznane klucze i pilnuje typów — storage bywa zaśmiecony po update'ach. */
export function sanitizeSettings(input) {
  const out = { ...DEFAULT_SETTINGS };
  for (const [key, fallback] of Object.entries(DEFAULT_SETTINGS)) {
    const value = input?.[key];
    if (value === undefined) continue;
    if (typeof fallback === 'boolean') out[key] = Boolean(value);
    else if (NUMERIC.has(key)) out[key] = Number.isFinite(Number(value)) ? Math.max(0, Number(value)) : fallback;
    else if (typeof fallback === 'string') out[key] = String(value);
  }
  if (!['pl', 'en'].includes(out.locale)) out.locale = DEFAULT_SETTINGS.locale;
  if (!MODES.includes(out.mode)) out.mode = DEFAULT_SETTINGS.mode;
  if (!SPEECH_BACKENDS.includes(out.speechBackend)) out.speechBackend = DEFAULT_SETTINGS.speechBackend;
  out.groqApiKey = out.groqApiKey.trim();
  out.bridgeToken = out.bridgeToken.trim();
  out.bridgeUrl = out.bridgeUrl.trim().replace(/\/+$/, '') || DEFAULT_SETTINGS.bridgeUrl;
  out.whisperUrl = out.whisperUrl.trim().replace(/\/+$/, '') || DEFAULT_SETTINGS.whisperUrl;
  if (!/^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$/.test(out.audioLang)) out.audioLang = DEFAULT_SETTINGS.audioLang;
  return out;
}

export async function loadSettings(storage = globalThis.chrome?.storage?.local) {
  if (!storage) return { ...DEFAULT_SETTINGS };
  const data = await storage.get(SETTINGS_KEY);
  return sanitizeSettings(data?.[SETTINGS_KEY]);
}

export async function saveSettings(patch, storage = globalThis.chrome?.storage?.local) {
  const current = await loadSettings(storage);
  const next = sanitizeSettings({ ...current, ...patch });
  await storage?.set({ [SETTINGS_KEY]: next });
  return next;
}
