/**
 * Content script — jedyne miejsce, które ma dostęp do DOM rozmowy.
 * Trzyma sesję w pamięci karty i wypycha migawki do service workera.
 */

import { Session } from '../src/core/session.js';
import { MeetAdapter } from '../src/adapters/meet/index.js';
import { MSG } from '../src/core/messages.js';
import { loadSettings } from '../src/core/settings.js';
import { meetingTitle, meetingCode } from '../src/adapters/meet/dom.js';
import { QuestionWatcher } from '../src/core/question-watcher.js';
import { buildPrompt } from '../src/core/assistant.js';
import { AssistantOverlay } from './overlay.js';

/** Nie zalewamy service workera — zapis co najwyżej raz na tyle ms. */
const PERSIST_THROTTLE_MS = 2000;
/** Ile razy próbować włączyć napisy, zanim UI Meeta się załaduje. */
const CAPTION_RETRIES = 20;
const CAPTION_RETRY_MS = 1500;

let state = null;

function inCall(href = location.href) {
  return Boolean(meetingCode(href));
}

function createSession(settings) {
  return new Session(
    {
      title: meetingTitle(document, location.href),
      source: MeetAdapter.id,
      url: location.href,
      startedAt: Date.now(),
    },
    { silenceMs: settings.silenceMs, mergeGapMs: settings.mergeGapMs },
  );
}

function snapshot() {
  if (!state) return { ok: false, reason: 'no-session' };
  const status = state.adapter.status;
  const segments = state.session.segments;
  const speakers = state.session.store.speakers;
  const words = speakers.reduce((acc, s) => acc + s.words, 0);
  return {
    ok: true,
    running: state.adapter.running,
    captions: status.captions,
    captionRoot: status.captionRoot,
    inCall: inCall(),
    meta: { ...state.session.meta, title: status.title || state.session.meta.title },
    startedAt: state.session.meta.startedAt,
    durationMs: Date.now() - state.session.meta.startedAt,
    segmentCount: segments.length,
    wordCount: words,
    speakers: speakers.map((s) => ({ name: s.name, segments: s.segments, words: s.words })),
    recent: segments.slice(-40),
  };
}

function persist({ final = false } = {}) {
  if (!state) return;
  const now = Date.now();
  if (!final && now - state.lastPersist < PERSIST_THROTTLE_MS) return;
  state.lastPersist = now;
  try {
    chrome.runtime.sendMessage(
      { type: MSG.PERSIST, session: state.session.toJSON(), final },
      () => void chrome.runtime.lastError,
    );
  } catch {
    /* service worker uśpiony albo strona się zamyka — nic nie tracimy, sesja żyje w karcie */
  }
}

function tryEnableCaptions(attempt = 0) {
  if (!state || attempt > CAPTION_RETRIES) return;
  if (state.adapter.enableCaptions()) return;
  if (state.adapter.status.captions === 'on') return;
  state.captionTimer = setTimeout(() => tryEnableCaptions(attempt + 1), CAPTION_RETRY_MS);
}

function startCapture() {
  if (!state || state.adapter.running) return;
  state.adapter.start();
  if (state.settings.autoEnableCaptions) tryEnableCaptions();
  persist({ final: true });
}

function stopCapture() {
  if (!state?.adapter.running) return;
  clearTimeout(state.captionTimer);
  state.adapter.stop();
  state.session.end();
  persist({ final: true });
}

function resetSession() {
  if (!state) return;
  const { settings } = state;
  const wasRunning = state.adapter.running;
  clearTimeout(state.captionTimer);
  state.adapter.stop();
  buildSession(settings);
  if (wasRunning || settings.autoStart) startCapture();
}

function buildSession(settings) {
  const session = createSession(settings);
  const adapter = new MeetAdapter({
    doc: document,
    store: session.store,
    onChange: () => {
      persist();
      scanForQuestions();
    },
  });
  state = { session, adapter, settings, lastPersist: 0, captionTimer: null, href: location.href };
  return state;
}

/* ---------- asystent ---------- */

let assistant = null;

function startAssistant(settings) {
  if (assistant || !settings.assistantEnabled) return;
  assistant = {
    overlay: new AssistantOverlay({ onAsk: (question) => askManual(question) }).mount(),
    watcher: new QuestionWatcher({
      onQuestion: (item) => askAssistant(item),
    }),
  };
  assistant.overlay.setBridgeState('ok', 'gotowy');
}

function stopAssistant() {
  assistant?.overlay.unmount();
  assistant = null;
}

function scanForQuestions() {
  if (!assistant || !state) return;
  assistant.watcher.scan(state.session.segments);
}

function askAssistant(item) {
  if (!assistant || !state) return;
  if (!state.settings.assistantAutoAsk) return;

  const prompt = buildPrompt({
    question: item.question,
    segments: state.session.segments,
    title: state.session.meta.title,
  });
  if (!prompt) return;

  assistant.overlay.ask({ question: item.question, speaker: item.speaker, prompt });
}

/**
 * Pytanie wpisane w nakładce.
 *
 * Omija wykrywanie i `assistantAutoAsk` — skoro ktoś je wpisał, to jest pytanie
 * i ma polecieć. Kontekst bierzemy z transkrypcji tak samo jak przy wykrytych,
 * więc „a ile to kosztuje?" wie, o czym była mowa.
 */
function askManual(question) {
  if (!assistant) return;

  const prompt = buildPrompt({
    question,
    segments: state?.session.segments ?? [],
    title: state?.session.meta.title ?? '',
  });
  if (!prompt) return;

  assistant.overlay.ask({ question, speaker: 'Ty', prompt, auto: false });
}

function watchNavigation() {
  setInterval(() => {
    if (!state) return;
    if (location.href === state.href) return;
    const wasInCall = Boolean(meetingCode(state.href));
    const nowInCall = inCall();
    const roomChanged = nowInCall && meetingCode(location.href) !== meetingCode(state.href);
    state.href = location.href;
    if (wasInCall && !nowInCall) stopCapture();
    else if (roomChanged) resetSession();
  }, 2000);
}

function handleMessage(message, _sender, sendResponse) {
  switch (message?.type) {
    case MSG.GET_STATE:
      sendResponse(snapshot());
      return false;
    case MSG.START:
      startCapture();
      sendResponse(snapshot());
      return false;
    case MSG.STOP:
      stopCapture();
      sendResponse(snapshot());
      return false;
    case MSG.RESET:
      resetSession();
      sendResponse(snapshot());
      return false;
    case MSG.ENABLE_CAPTIONS:
      sendResponse({ ok: state?.adapter.enableCaptions() ?? false });
      return false;

    case MSG.ASSISTANT_STATE:
      if (message.enabled) startAssistant({ ...state?.settings, assistantEnabled: true });
      else stopAssistant();
      if (state) state.settings = { ...state.settings, assistantEnabled: Boolean(message.enabled) };
      sendResponse({ ok: true, running: Boolean(assistant) });
      return false;
    case MSG.GET_SESSION:
      sendResponse(state ? state.session.toJSON() : { ok: false });
      return false;
    default:
      return false;
  }
}

export async function boot() {
  if (globalThis.__callWhisperBooted) return;
  globalThis.__callWhisperBooted = true;

  const settings = await loadSettings();
  buildSession(settings);

  chrome.runtime.onMessage.addListener(handleMessage);
  watchNavigation();

  // Rozmowa się kończy razem z kartą — domykamy i zapisujemy synchronicznie.
  addEventListener('pagehide', () => {
    stopAssistant();
    if (!state?.adapter.running) return;
    stopCapture();
  });

  if (settings.autoStart && inCall()) startCapture();
  if (settings.assistantEnabled && inCall()) startAssistant(settings);

  console.info('[call-whisper] gotowy — %s', settings.autoStart ? 'nagrywam' : 'czekam na start');
}
