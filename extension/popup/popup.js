/**
 * Popup — cienki klient. Cała logika transkrypcji siedzi w content scripcie,
 * tutaj tylko odpytujemy stan, renderujemy i wołamy eksport.
 */

import { MSG } from '../src/core/messages.js';
import { renderMarkdown } from '../src/core/markdown.js';
import { Session } from '../src/core/session.js';
import { formatOffset, formatDuration } from '../src/core/time.js';
import { DEFAULT_SETTINGS } from '../src/core/settings.js';

const REFRESH_MS = 1000;
const MEET_URL = /^https:\/\/meet\.google\.com\//;

/** Kolory mówców — akcenty z palety HeroUI. */
const SPEAKER_COLORS = [
  '#006FEE', // primary
  '#7828C8', // secondary
  '#17C964', // success
  '#F5A524', // warning
  '#F31260', // danger
  '#0E8AAA',
  '#C4841D',
  '#6020A0',
];

const $ = (id) => document.getElementById(id);

const el = {
  statusChip: $('status-chip'),
  sourceLabel: $('source-label'),
  settingsToggle: $('settings-toggle'),
  panelLive: $('panel-live'),
  panelSettings: $('panel-settings'),
  meetingTitle: $('meeting-title'),
  meetingSub: $('meeting-sub'),
  duration: $('stat-duration'),
  segments: $('stat-segments'),
  words: $('stat-words'),
  speakersCount: $('stat-speakers'),
  alert: $('alert'),
  alertTag: $('alert-tag'),
  alertText: $('alert-text'),
  alertAction: $('alert-action'),
  speakers: $('speakers'),
  transcript: $('transcript'),
  toggleCapture: $('toggle-capture'),
  copyMd: $('copy-md'),
  saveMd: $('save-md'),
  saveJson: $('save-json'),
  localeSwitch: $('locale-switch'),
  modeSwitch: $('mode-switch'),
  audioLang: $('audio-lang'),
  speechBackend: $('speech-backend'),
  groqKey: $('groq-key'),
  groqModel: $('groq-model'),
  groqFields: $('groq-fields'),
  whisperFields: $('whisper-fields'),
  whisperUrl: $('whisper-url'),
  whisperCheck: $('whisper-check'),
  whisperStatus: $('whisper-status'),
  privacyNote: $('privacy-note'),
  bridgeUrl: $('bridge-url'),
  bridgeCheck: $('bridge-check'),
  bridgeStatus: $('bridge-status'),
  micPermission: $('mic-permission'),
  captionsSettings: $('captions-settings'),
};

let view = null;
let settings = { ...DEFAULT_SETTINGS };
let tabId = null;
let activeTab = null;
/**
 * Błąd ostatniej akcji użytkownika.
 *
 * Trzymany osobno, bo `renderAlert` odtwarza alert wyłącznie ze stanu sesji
 * i leci co sekundę — bez tego komunikat o nieudanym starcie znikał, zanim
 * dało się go przeczytać.
 */
let actionError = null;
let refreshTimer = null;
let pinnedToBottom = true;

const speakerColor = (() => {
  const assigned = new Map();
  return (name) => {
    if (!assigned.has(name)) assigned.set(name, SPEAKER_COLORS[assigned.size % SPEAKER_COLORS.length]);
    return assigned.get(name);
  };
})();

/* ---------- komunikacja ---------- */

async function sendToTab(type, payload = {}) {
  if (tabId == null) return null;
  try {
    return await chrome.tabs.sendMessage(tabId, { type, ...payload });
  } catch {
    return null; // brak content scriptu na tej karcie
  }
}

async function sendToWorker(type, payload = {}) {
  try {
    return await chrome.runtime.sendMessage({ type, ...payload });
  } catch {
    return null;
  }
}

/* ---------- pobranie stanu ---------- */

async function pullState() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  activeTab = tab ?? null;
  tabId = MEET_URL.test(tab?.url ?? '') ? tab.id : null;

  if (settings.mode === 'audio') return pullAudioState();

  const live = await sendToTab(MSG.GET_STATE);
  if (live?.ok) {
    view = { live: true, ...live };
    return view;
  }

  const stored = await sendToWorker(MSG.GET_LAST);
  const session = stored?.last?.session ?? null;
  if (!session) {
    view = { live: false, empty: true };
    return view;
  }

  const segments = session.segments ?? [];
  const names = new Map();
  for (const s of segments) names.set(s.speaker, (names.get(s.speaker) ?? 0) + 1);
  view = {
    live: false,
    running: false,
    meta: session.meta,
    startedAt: session.meta?.startedAt,
    durationMs: (session.meta?.endedAt ?? session.meta?.startedAt ?? 0) - (session.meta?.startedAt ?? 0),
    segmentCount: segments.length,
    wordCount: segments.reduce((acc, s) => acc + (s.text ? s.text.split(/\s+/).length : 0), 0),
    speakers: [...names].map(([name, count]) => ({ name, segments: count })),
    recent: segments.slice(-40),
    session,
  };
  return view;
}

function sessionEndMs(session, running) {
  if (running) return Date.now();
  const segments = session?.segments ?? [];
  return session?.meta?.endedAt ?? segments.at(-1)?.endedAt ?? session?.meta?.startedAt ?? Date.now();
}

/** Widok dla trybu audio — źródłem prawdy jest dokument offscreen przez storage. */
async function pullAudioState() {
  const response = await sendToWorker(MSG.AUDIO_STATE);
  const entry = response?.entry ?? null;
  const running = Boolean(response?.running);
  const session = entry?.session ?? null;
  const status = entry?.status ?? null;

  if (!session) {
    view = {
      live: true,
      mode: 'audio',
      running,
      inCall: Boolean(activeTab?.id),
      meta: { title: activeTab?.title || 'Ta karta', source: 'audio' },
      durationMs: 0,
      segmentCount: 0,
      wordCount: 0,
      speakers: [],
      recent: [],
      warnings: status?.warnings ?? [],
      errors: status?.errors ?? [],
      recognition: status?.recognition ?? null,
      session: null,
    };
    return view;
  }

  const segments = session.segments ?? [];
  const names = new Map();
  for (const segment of segments) names.set(segment.speaker, (names.get(segment.speaker) ?? 0) + 1);

  view = {
    live: true,
    mode: 'audio',
    running,
    inCall: Boolean(activeTab?.id),
    meta: session.meta,
    startedAt: session.meta?.startedAt,
    // Zatrzymana sesja nie może mieć rosnącego licznika: gdy brak `endedAt`,
    // bierzemy koniec ostatniej wypowiedzi, a nie bieżący czas.
    durationMs: Math.max(0, sessionEndMs(session, running) - (session.meta?.startedAt ?? Date.now())),
    segmentCount: segments.length,
    wordCount: segments.reduce((acc, s) => acc + (s.text ? s.text.split(/\s+/).length : 0), 0),
    speakers: [...names].map(([name, count]) => ({ name, segments: count })),
    recent: segments.slice(-40),
    warnings: status?.warnings ?? [],
    errors: status?.errors ?? [],
    recognition: status?.recognition ?? null,
    session,
  };
  return view;
}

async function getSession() {
  if (view?.mode === 'audio') return view.session ?? null;
  if (view?.live) {
    const session = await sendToTab(MSG.GET_SESSION);
    if (session?.meta) return session;
  }
  return view?.session ?? null;
}

/* ---------- render ---------- */

function setChip(text, variant) {
  el.statusChip.textContent = text;
  el.statusChip.className = `hero-chip hero-chip--dot${variant ? ` hero-chip--${variant}` : ''}`;
}

function showAlert({ tag, tagVariant = 'warning', text, action }) {
  el.alert.hidden = false;
  el.alertTag.textContent = tag;
  el.alertTag.className = `hero-chip hero-chip--${tagVariant} hero-chip--dot`;
  el.alertText.textContent = text;
  if (action) {
    el.alertAction.hidden = false;
    el.alertAction.textContent = action.label;
    el.alertAction.onclick = action.onClick;
  } else {
    el.alertAction.hidden = true;
    el.alertAction.onclick = null;
  }
}

function renderStatus(state) {
  if (state.empty) return setChip('brak sesji', null);
  if (state.mode === 'audio') {
    if (!state.inCall) return setChip('brak karty', null);
    return state.running ? setChip('słucham', 'danger') : setChip('gotowy', null);
  }
  if (!state.live) return setChip('zapisana sesja', null);
  if (!state.inCall) return setChip('poza rozmową', null);
  if (state.running) return setChip('nagrywam', 'success');
  return setChip('wstrzymane', 'warning');
}

/** Kolejność ma znaczenie — pokazujemy najpoważniejszy problem. */
const AUDIO_WARNINGS = [
  {
    code: 'no-api',
    tag: 'Chrome',
    variant: 'danger',
    text: 'Ta wersja Chrome nie ma Web Speech API. Wymagany Chrome 133+.',
  },
  {
    code: 'model-missing',
    tag: 'model',
    variant: 'warning',
    text:
      'Brak lokalnego modelu mowy. Włącz w Chrome „Napisy na żywo" i dodaj swój język — ' +
      'to pobiera ten sam model. Transkrypcja ruszy sama, gdy będzie gotowy.',
    action: { label: 'Otwórz ustawienia napisów', message: MSG.OPEN_CAPTIONS_SETTINGS },
  },
  {
    code: 'whisper-no-url',
    tag: 'whisper',
    variant: 'warning',
    text: 'Brak adresu lokalnego whisper.cpp. Uzupełnij go w ustawieniach i uruchom `npm run whisper`.',
  },
  {
    code: 'using-cloud',
    tag: 'chmura',
    variant: 'warning',
    text: 'Rozpoznaję w chmurze Google — audio opuszcza to urządzenie.',
  },
  {
    code: 'groq-no-key',
    tag: 'Groq',
    variant: 'danger',
    text: 'Wybrano Groq, ale nie ma klucza API. Wklej go w ustawieniach.',
  },
  {
    code: 'mic-denied',
    tag: 'mikrofon',
    variant: 'warning',
    text: 'Brak dostępu do mikrofonu — nagrywam tylko dźwięk karty.',
    action: { label: 'Nadaj dostęp', message: MSG.OPEN_MIC_PERMISSION },
  },
];

function renderAlert(state) {
  el.alert.hidden = true;

  // Błąd akcji ma pierwszeństwo i nie znika przy odświeżeniu.
  if (actionError) {
    showAlert({
      tag: actionError.tag ?? 'błąd',
      tagVariant: 'danger',
      text: actionError.text,
      action: { label: 'OK', onClick: () => { actionError = null; render(view); } },
    });
    return;
  }

  if (state.mode === 'audio') {
    const codes = new Set(state.warnings ?? []);
    const warning = AUDIO_WARNINGS.find((w) => codes.has(w.code));
    if (warning) {
      showAlert({
        tag: warning.tag,
        tagVariant: warning.variant,
        text: warning.text,
        action: warning.action
          ? { label: warning.action.label, onClick: () => sendToWorker(warning.action.message) }
          : null,
      });
      return;
    }

    // Błąd z samego rozpoznawania — lepszy niż wieczne „czekam".
    const error = (state.errors ?? [])[0];
    if (error) {
      showAlert({ tag: 'błąd ASR', tagVariant: 'danger', text: `Rozpoznawanie zwróciło: ${error}` });
      return;
    }

    if (state.running && state.segmentCount === 0) {
      showAlert({ tag: 'słucham', tagVariant: 'primary', text: 'Czekam, aż ktoś się odezwie.' });
    }
    return;
  }

  if (!state.live || !state.inCall) return;

  if (state.captions === 'off') {
    showAlert({
      tag: 'napisy',
      text: 'Napisy w Meecie są wyłączone — bez nich nie ma czego transkrybować.',
      action: {
        label: 'Włącz napisy',
        onClick: async () => {
          await sendToTab(MSG.ENABLE_CAPTIONS);
          await refresh();
        },
      },
    });
    return;
  }

  if (state.running && state.captions === 'on' && !state.captionRoot && state.segmentCount === 0) {
    showAlert({
      tag: 'czekam',
      tagVariant: 'primary',
      text: 'Napisy włączone, ale nikt jeszcze nic nie powiedział.',
    });
  }
}

function renderSpeakers(state) {
  el.speakers.replaceChildren();
  for (const speaker of state.speakers ?? []) {
    const chip = document.createElement('span');
    chip.className = 'cw-speaker';

    const dot = document.createElement('span');
    dot.className = 'cw-speaker__dot';
    dot.style.background = speakerColor(speaker.name);

    const name = document.createElement('span');
    name.className = 'cw-speaker__name';
    name.textContent = speaker.name;

    const count = document.createElement('span');
    count.className = 'cw-speaker__count';
    count.textContent = String(speaker.segments);

    chip.append(dot, name, count);
    el.speakers.append(chip);
  }
}

function renderTranscript(state) {
  const segments = state.recent ?? [];
  if (!segments.length) {
    const empty = document.createElement('p');
    empty.className = 'cw-empty hero-text-tiny hero-text-muted';
    empty.textContent = state.live
      ? 'Czekam na pierwsze wypowiedzi…'
      : 'Ta sesja nie ma jeszcze transkrypcji.';
    el.transcript.replaceChildren(empty);
    return;
  }

  const fragment = document.createDocumentFragment();
  for (const segment of segments) {
    const line = document.createElement('div');
    line.className = `cw-line${segment.final === false ? ' cw-line--live' : ''}`;

    const meta = document.createElement('div');
    meta.className = 'cw-line__meta';

    const dot = document.createElement('span');
    dot.className = 'cw-line__dot';
    dot.style.background = speakerColor(segment.speaker);

    const who = document.createElement('span');
    who.className = 'cw-line__speaker';
    who.textContent = segment.speaker;

    const time = document.createElement('span');
    time.className = 'cw-line__time';
    time.textContent = formatOffset(segment.offsetMs ?? 0);

    meta.append(dot, who, time);

    const text = document.createElement('div');
    text.className = 'cw-line__text';
    text.textContent = segment.text;

    line.append(meta, text);
    fragment.append(line);
  }

  el.transcript.replaceChildren(fragment);
  if (pinnedToBottom) el.transcript.scrollTop = el.transcript.scrollHeight;
}

function render(state) {
  renderStatus(state);
  el.sourceLabel.textContent = settings.mode === 'audio' ? 'Rozpoznawanie głosu' : 'Google Meet';

  if (state.empty) {
    el.meetingTitle.textContent = 'Brak nagranej rozmowy';
    el.meetingSub.textContent = 'Wejdź na spotkanie w Google Meet';
    el.duration.textContent = '00:00:00';
    el.segments.textContent = '0';
    el.words.textContent = '0';
    el.speakersCount.textContent = '0';
    el.speakers.replaceChildren();
    renderTranscript({ recent: [], live: false });
    el.toggleCapture.disabled = true;
    el.copyMd.disabled = true;
    el.saveMd.disabled = true;
    el.saveJson.disabled = true;
    return;
  }

  el.meetingTitle.textContent = state.meta?.title || 'Rozmowa';
  el.meetingSub.textContent = describeSource(state);

  el.duration.textContent = formatOffset(state.durationMs ?? 0);
  el.segments.textContent = String(state.segmentCount ?? 0);
  el.words.textContent = String(state.wordCount ?? 0);
  el.speakersCount.textContent = String(state.speakers?.length ?? 0);

  renderAlert(state);
  renderSpeakers(state);
  renderTranscript(state);

  const hasData = (state.segmentCount ?? 0) > 0;
  el.copyMd.disabled = !hasData;
  el.saveMd.disabled = !hasData;
  el.saveJson.disabled = !hasData;

  el.toggleCapture.disabled = state.mode === 'audio' ? !state.inCall : !state.live || !state.inCall;
  el.toggleCapture.textContent = state.running
    ? 'Zatrzymaj'
    : state.mode === 'audio'
      ? 'Słuchaj tej karty'
      : 'Start';
  el.toggleCapture.className = `hero-button hero-button--full ${
    state.running ? 'hero-button--flat hero-button--danger' : 'hero-button--primary'
  }`;
}

const SOURCE_NAMES = { 'google-meet': 'Google Meet', audio: 'rozpoznawanie głosu' };

function describeSource(state) {
  const name = SOURCE_NAMES[state.meta?.source] ?? state.meta?.source ?? '';
  const duration = formatDuration(state.durationMs ?? 0);
  if (state.mode === 'audio') {
    const parts = ['dźwięk karty'];
    if (settings.captureMic) parts.push('mikrofon');
    const where = {
      local: 'lokalnie',
      cloud: 'chmura Google',
      groq: 'Groq Whisper',
      'whisper-local': 'whisper.cpp lokalnie',
    }[state.recognition];
    return `${parts.join(' + ')} · ${duration}${where ? ` · ${where}` : ''}`;
  }
  return state.live ? `${name} · ${duration}` : `zapisana ${duration}`;
}

function paintMode() {
  for (const button of el.modeSwitch.querySelectorAll('[data-mode]')) {
    button.setAttribute('aria-pressed', String(button.dataset.mode === settings.mode));
  }
}

/* ---------- akcje ---------- */

function flash(button, label) {
  const original = button.textContent;
  button.textContent = label;
  setTimeout(() => {
    button.textContent = original;
  }, 1400);
}

async function onToggleCapture() {
  if (settings.mode === 'audio') return onToggleAudio();

  const next = view?.running ? MSG.STOP : MSG.START;
  const state = await sendToTab(next);
  if (state?.ok) {
    view = { live: true, ...state };
    render(view);
  }
}

async function onToggleAudio() {
  if (view?.running) {
    await sendToWorker(MSG.AUDIO_STOP);
    await refresh();
    return;
  }
  if (!activeTab?.id) return;

  el.toggleCapture.disabled = true;
  el.toggleCapture.textContent = 'Uruchamiam…';
  // getMediaStreamId wymaga gestu użytkownika — to kliknięcie nim jest.
  const response = await sendToWorker(MSG.AUDIO_START, {
    tabId: activeTab.id,
    withMic: settings.captureMic,
    lang: settings.audioLang,
    allowCloud: settings.allowCloudSpeech,
    backend: settings.speechBackend,
    groq: { apiKey: settings.groqApiKey, model: settings.groqModel },
    whisper: { url: settings.whisperUrl },
  });

  if (response?.ok) {
    actionError = null;
  } else {
    actionError = {
      tag: 'start',
      text: response?.error ?? 'Nie udało się uruchomić przechwytywania audio.',
    };
    el.toggleCapture.disabled = false;
  }
  await refresh();
}

async function onCopy() {
  const session = await getSession();
  if (!session) return;
  // Domykamy segmenty, żeby w schowku nie było znacznika "w trakcie".
  const markdown = renderMarkdown(Session.fromJSON(session).toJSON(), {
    locale: settings.locale,
    frontmatter: settings.frontmatter,
    absoluteTimestamps: settings.absoluteTimestamps,
    stats: settings.stats,
  });
  await navigator.clipboard.writeText(markdown);
  flash(el.copyMd, 'Skopiowane');
}

async function onSave(format) {
  const session = await getSession();
  if (!session) return;
  await sendToWorker(MSG.DOWNLOAD, { session, format });
  flash(format === 'json' ? el.saveJson : el.saveMd, 'Zapisano');
}

/* ---------- ustawienia ---------- */

const CONSENT_NOTE = 'Nagrywanie rozmowy może wymagać zgody pozostałych uczestników.';

/**
 * Notka o prywatności musi odpowiadać faktycznej konfiguracji — obietnica
 * „wszystko lokalnie" przestaje być prawdziwa, gdy audio leci do Groqa
 * albo do chmury Google.
 */
function privacyNote() {
  if (settings.mode !== 'audio') {
    return `Napisy czytane są ze strony — audio nigdzie nie wychodzi. ${CONSENT_NOTE}`;
  }
  if (settings.speechBackend === 'groq') {
    return `Audio wypowiedzi jest wysyłane do Groqa w celu transkrypcji. ${CONSENT_NOTE}`;
  }
  if (settings.speechBackend === 'whisper-local') {
    return `Transkrypcja przez whisper.cpp na tym komputerze — audio nie opuszcza urządzenia. ${CONSENT_NOTE}`;
  }
  if (settings.allowCloudSpeech) {
    return `Przy braku modelu lokalnego audio trafia do chmury Google. ${CONSENT_NOTE}`;
  }
  return `Rozpoznawanie działa lokalnie — audio nie opuszcza urządzenia. ${CONSENT_NOTE}`;
}

function paintSettings() {
  for (const input of document.querySelectorAll('input[data-setting]')) {
    input.checked = Boolean(settings[input.dataset.setting]);
  }
  if (el.audioLang) el.audioLang.value = settings.audioLang;
  if (el.speechBackend) el.speechBackend.value = settings.speechBackend;
  if (el.groqModel) el.groqModel.value = settings.groqModel;
  // Klucza nie nadpisujemy w trakcie pisania — tylko gdy pole jest puste.
  if (el.groqKey && !el.groqKey.value) el.groqKey.value = settings.groqApiKey;
  if (el.groqFields) el.groqFields.hidden = settings.speechBackend !== 'groq';
  if (el.whisperFields) el.whisperFields.hidden = settings.speechBackend !== 'whisper-local';
  if (el.whisperUrl && !el.whisperUrl.value) el.whisperUrl.value = settings.whisperUrl;
  if (el.privacyNote) el.privacyNote.textContent = privacyNote();
  if (el.bridgeUrl && !el.bridgeUrl.value) el.bridgeUrl.value = settings.bridgeUrl;
  paintMode();
  for (const button of el.localeSwitch.querySelectorAll('[data-locale]')) {
    button.setAttribute('aria-pressed', String(button.dataset.locale === settings.locale));
  }
}

async function patchSettings(patch) {
  const response = await sendToWorker(MSG.SET_SETTINGS, { patch });
  if (response?.settings) settings = response.settings;
  paintSettings();
}

function wireSettings() {
  for (const input of document.querySelectorAll('input[data-setting]')) {
    if (input.type !== 'checkbox') continue;
    input.addEventListener('change', async () => {
      await patchSettings({ [input.dataset.setting]: input.checked });
      // Nakładka asystenta żyje w karcie — musi dowiedzieć się od razu.
      if (input.dataset.setting === 'assistantEnabled') {
        await sendToTab(MSG.ASSISTANT_STATE, { enabled: input.checked });
      }
    });
  }
  el.audioLang?.addEventListener('change', () => patchSettings({ audioLang: el.audioLang.value }));
  el.speechBackend?.addEventListener('change', () => {
    actionError = null;
    patchSettings({ speechBackend: el.speechBackend.value });
  });
  el.groqModel?.addEventListener('change', () => patchSettings({ groqModel: el.groqModel.value }));
  el.groqKey?.addEventListener('change', () => patchSettings({ groqApiKey: el.groqKey.value.trim() }));
  el.micPermission?.addEventListener('click', () => sendToWorker(MSG.OPEN_MIC_PERMISSION));
  el.captionsSettings?.addEventListener('click', () => sendToWorker(MSG.OPEN_CAPTIONS_SETTINGS));
  el.bridgeUrl?.addEventListener('change', () => patchSettings({ bridgeUrl: el.bridgeUrl.value.trim() }));
  el.bridgeCheck?.addEventListener('click', checkBridge);
  el.whisperUrl?.addEventListener('change', () => patchSettings({ whisperUrl: el.whisperUrl.value.trim() }));
  el.whisperCheck?.addEventListener('click', checkWhisper);
  for (const button of el.modeSwitch.querySelectorAll('[data-mode]')) {
    button.addEventListener('click', async () => {
      await patchSettings({ mode: button.dataset.mode });
      await refresh();
    });
  }
  for (const button of el.localeSwitch.querySelectorAll('[data-locale]')) {
    button.addEventListener('click', () => patchSettings({ locale: button.dataset.locale }));
  }
  el.settingsToggle.addEventListener('click', () => {
    const showSettings = el.panelSettings.hidden;
    el.panelSettings.hidden = !showSettings;
    el.panelLive.hidden = showSettings;
    el.settingsToggle.setAttribute('aria-pressed', String(showSettings));
  });
}

async function checkWhisper() {
  el.whisperStatus.textContent = 'serwer: sprawdzam…';
  const result = await sendToWorker(MSG.WHISPER_HEALTH);
  el.whisperStatus.textContent = result?.ok
    ? 'serwer: działa'
    : `serwer: ${result?.error ?? 'brak odpowiedzi'}`;
}

async function checkBridge() {
  el.bridgeStatus.textContent = 'most: sprawdzam…';
  const health = await sendToWorker(MSG.BRIDGE_HEALTH);
  if (health?.ok) {
    const claude = health.claude ?? {};
    el.bridgeStatus.textContent = `most: działa${claude.busy ? ' (zajęty)' : ''}`;
  } else {
    el.bridgeStatus.textContent = `most: ${health?.error ?? 'brak odpowiedzi'}`;
  }
}

/* ---------- pętla ---------- */

async function refresh() {
  render(await pullState());
}

async function init() {
  el.transcript.addEventListener('scroll', () => {
    const distance = el.transcript.scrollHeight - el.transcript.scrollTop - el.transcript.clientHeight;
    pinnedToBottom = distance < 24;
  });

  el.toggleCapture.addEventListener('click', onToggleCapture);
  el.copyMd.addEventListener('click', onCopy);
  el.saveMd.addEventListener('click', () => onSave('md'));
  el.saveJson.addEventListener('click', () => onSave('json'));
  wireSettings();

  const response = await sendToWorker(MSG.GET_SETTINGS);
  if (response?.settings) settings = response.settings;
  paintSettings();

  await refresh();
  refreshTimer = setInterval(refresh, REFRESH_MS);
  addEventListener('pagehide', () => clearInterval(refreshTimer));
}

init().catch((error) => {
  console.error('[call-whisper] popup:', error);
  setChip('błąd', 'danger');
});
