/**
 * Service worker — trwałość sesji i eksport plików.
 *
 * Content script jest źródłem prawdy dopóki karta żyje; tutaj trzymamy kopię,
 * żeby popup miał co pokazać po odświeżeniu strony i żeby dało się zapisać
 * transkrypt po zamknięciu rozmowy.
 */

import { MSG } from './src/core/messages.js';
import { renderMarkdown } from './src/core/markdown.js';
import { Session } from './src/core/session.js';
import { loadSettings, saveSettings } from './src/core/settings.js';
import { BridgeClient } from './src/adapters/assistant/client.js';
import { WhisperLocalClient } from './src/adapters/audio/whisper-local.js';
import { waitFor } from './src/core/wait.js';

const TAB_KEY = (tabId) => `cw:tab:${tabId}`;
const AUDIO_KEY = 'cw:audio';
const OFFSCREEN_URL = 'offscreen/offscreen.html';
const LAST_KEY = 'cw:last';
/** Ile zakończonych sesji trzymamy w historii. */
const HISTORY_KEY = 'cw:history';
const HISTORY_LIMIT = 10;

const badge = {
  async set(tabId, text, color) {
    try {
      await chrome.action.setBadgeText({ tabId, text });
      if (color) await chrome.action.setBadgeBackgroundColor({ tabId, color });
    } catch {
      /* karta zniknęła */
    }
  },
};

async function persistSession(tabId, session, final, status = null) {
  const payload = { session, updatedAt: Date.now(), tabId, final, status };
  const patch = { [TAB_KEY(tabId)]: payload, [LAST_KEY]: payload };
  // Sesja audio ma własny slot — popup pokazuje ją niezależnie od karty.
  if (status?.mode === 'audio') patch[AUDIO_KEY] = payload;
  await chrome.storage.local.set(patch);
  const count = session?.segments?.length ?? 0;
  await badge.set(tabId, count ? String(count) : '', '#17c964');
  if (final) await pushHistory(session);
}

async function pushHistory(session) {
  if (!session?.segments?.length) return;
  const data = await chrome.storage.local.get(HISTORY_KEY);
  const history = Array.isArray(data[HISTORY_KEY]) ? data[HISTORY_KEY] : [];
  const withoutDuplicate = history.filter((entry) => entry?.meta?.id !== session.meta?.id);
  withoutDuplicate.unshift(session);
  await chrome.storage.local.set({ [HISTORY_KEY]: withoutDuplicate.slice(0, HISTORY_LIMIT) });
}

function toDataUrl(text, mime) {
  return `data:${mime};charset=utf-8,${encodeURIComponent(text)}`;
}

async function download({ session, format = 'md', saveAs = false }) {
  const restored = Session.fromJSON(session);
  const settings = await loadSettings();
  const isJson = format === 'json';
  // Markdown renderujemy ze znormalizowanej sesji — Session.fromJSON domyka
  // wszystkie segmenty, więc w zapisanym pliku nie ma znacznika "w trakcie".
  const body = isJson
    ? JSON.stringify(session, null, 2)
    : renderMarkdown(restored.toJSON(), {
        locale: settings.locale,
        frontmatter: settings.frontmatter,
        absoluteTimestamps: settings.absoluteTimestamps,
        stats: settings.stats,
      });

  const id = await chrome.downloads.download({
    url: toDataUrl(body, isJson ? 'application/json' : 'text/markdown'),
    filename: `call-whisper/${restored.filename(isJson ? 'json' : 'md')}`,
    saveAs,
  });
  return { ok: true, id };
}

async function autoSave(tabId) {
  const settings = await loadSettings();
  if (!settings.autoSaveOnEnd) return;
  const data = await chrome.storage.local.get(TAB_KEY(tabId));
  const entry = data[TAB_KEY(tabId)];
  if (!entry?.session?.segments?.length) return;
  await pushHistory(entry.session);
  await download({ session: entry.session, format: 'md' });
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const tabId = sender?.tab?.id;

  switch (message?.type) {
    case MSG.PERSIST: {
      // Content script ma sender.tab, dokument offscreen podaje tabId jawnie.
      const target = message.tabId ?? tabId;
      if (typeof target === 'number') {
        persistSession(target, message.session, message.final, message.status ?? null).catch(console.error);
      }
      sendResponse({ ok: true });
      return false;
    }

    case MSG.AUDIO_START:
      startAudioCapture(message).then(sendResponse).catch((error) =>
        sendResponse({ ok: false, error: String(error?.message ?? error) }),
      );
      return true;

    case MSG.AUDIO_STOP:
      stopAudioCapture().then(sendResponse).catch(() => sendResponse({ ok: false }));
      return true;

    case MSG.AUDIO_STATE:
      audioState().then(sendResponse).catch(() => sendResponse({ ok: false }));
      return true;

    case MSG.BRIDGE_HEALTH:
      bridgeHealth().then(sendResponse).catch((error) => sendResponse({ ok: false, error: String(error) }));
      return true;

    case MSG.WHISPER_HEALTH:
      loadSettings()
        .then((settings) => new WhisperLocalClient({ endpoint: settings.whisperUrl }).health())
        .then(sendResponse)
        .catch((error) => sendResponse({ ok: false, error: String(error) }));
      return true;

    case MSG.OPEN_CAPTIONS_SETTINGS:
      // Napisy na żywo pobierają komponent SODA — ten sam model, którego
      // używa rozpoznawanie lokalne.
      chrome.tabs
        .create({ url: 'chrome://settings/captions' })
        .then(() => sendResponse({ ok: true }))
        .catch((error) => sendResponse({ ok: false, error: String(error) }));
      return true;

    case MSG.OPEN_MIC_PERMISSION:
      chrome.tabs
        .create({ url: chrome.runtime.getURL('permission/mic.html') })
        .then(() => sendResponse({ ok: true }))
        .catch(() => sendResponse({ ok: false }));
      return true;

    case MSG.DOWNLOAD:
      download(message).then(sendResponse).catch((error) => sendResponse({ ok: false, error: String(error) }));
      return true;

    case MSG.GET_LAST:
      chrome.storage.local.get([LAST_KEY, HISTORY_KEY]).then((data) =>
        sendResponse({ ok: true, last: data[LAST_KEY] ?? null, history: data[HISTORY_KEY] ?? [] }),
      );
      return true;

    case MSG.GET_SETTINGS:
      loadSettings().then((settings) => sendResponse({ ok: true, settings }));
      return true;

    case MSG.SET_SETTINGS:
      saveSettings(message.patch ?? {}).then((settings) => sendResponse({ ok: true, settings }));
      return true;

    default:
      return false;
  }
});

/* ---------- tryb audio: rozpoznawanie po głosie ---------- */

async function hasOffscreen() {
  const contexts = await chrome.runtime.getContexts({
    contextTypes: ['OFFSCREEN_DOCUMENT'],
    documentUrls: [chrome.runtime.getURL(OFFSCREEN_URL)],
  });
  return contexts.length > 0;
}

/** Czy dokument offscreen ma już zarejestrowany listener i odpowiada. */
async function offscreenResponds() {
  try {
    const response = await chrome.runtime.sendMessage({ target: 'offscreen', type: MSG.OFFSCREEN_STATUS });
    return Boolean(response?.ok);
  } catch {
    return false;
  }
}

/** Równoległe wywołania nie mogą próbować tworzyć dwóch dokumentów naraz. */
let offscreenCreation = null;

/**
 * Tworzy dokument offscreen i CZEKA, aż faktycznie zacznie odpowiadać.
 *
 * `createDocument()` wraca, gdy dokument istnieje — ale jego skrypt jest
 * modułem ES i ładuje się dalej. Wysłanie `OFFSCREEN_START` od razu po
 * utworzeniu trafiało w pustkę: listener nie był jeszcze zarejestrowany,
 * `sendMessage` odrzucał obietnicę i start cicho padał.
 */
async function ensureOffscreen() {
  if (await offscreenResponds()) return true;

  if (!offscreenCreation) {
    offscreenCreation = (async () => {
      if (!(await hasOffscreen())) {
        try {
          await chrome.offscreen.createDocument({
            url: OFFSCREEN_URL,
            reasons: ['USER_MEDIA'],
            justification: 'Przechwytywanie audio rozmowy do lokalnej transkrypcji',
          });
        } catch (error) {
          // Wyścig: ktoś zdążył utworzyć dokument między naszym sprawdzeniem
          // a wywołaniem. To nie jest błąd, o ile dokument istnieje.
          if (!(await hasOffscreen())) throw error;
        }
      }
      return waitFor(offscreenResponds, { timeoutMs: 5000, intervalMs: 100 });
    })().finally(() => {
      offscreenCreation = null;
    });
  }
  return offscreenCreation;
}

async function closeOffscreen() {
  if (await hasOffscreen()) await chrome.offscreen.closeDocument();
}

/**
 * Start przechwytywania. `getMediaStreamId` wymaga świeżego gestu użytkownika —
 * wywołanie idzie z kliknięcia w popupie, więc gest jest spełniony.
 */
async function startAudioCapture({
  tabId,
  withMic = true,
  lang = 'pl-PL',
  allowCloud = false,
  backend = 'webspeech',
  groq = {},
  whisper = {},
}) {
  const tab = await chrome.tabs.get(tabId);
  const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tabId });

  if (!(await ensureOffscreen())) {
    return { ok: false, error: 'Dokument offscreen nie wystartował w 5 s' };
  }

  const response = await chrome.runtime.sendMessage({
    target: 'offscreen',
    type: MSG.OFFSCREEN_START,
    streamId,
    withMic,
    lang,
    allowCloud,
    backend,
    groq,
    whisper,
    tabId,
    title: tab?.title ?? 'Rozmowa',
    url: tab?.url ?? '',
  });

  if (!response?.ok) {
    await closeOffscreen();
    return { ok: false, error: response?.error ?? 'nie udało się uruchomić przechwytywania' };
  }
  await badge.set(tabId, '●', '#f31260');
  return response;
}

async function stopAudioCapture() {
  if (await hasOffscreen()) {
    await chrome.runtime.sendMessage({ target: 'offscreen', type: MSG.OFFSCREEN_STOP }).catch(() => {});
    await closeOffscreen();
  }
  const data = await chrome.storage.local.get(AUDIO_KEY);
  const entry = data[AUDIO_KEY];
  if (entry?.tabId != null) await badge.set(entry.tabId, '', '#17c964');
  return { ok: true };
}

async function audioState() {
  const [data, running] = await Promise.all([chrome.storage.local.get(AUDIO_KEY), hasOffscreen()]);
  return { ok: true, running, entry: data[AUDIO_KEY] ?? null };
}

/* ---------- asystent: most do Claude Code ---------- */

async function bridgeClient() {
  const settings = await loadSettings();
  return new BridgeClient({ endpoint: settings.bridgeUrl, token: settings.bridgeToken || null });
}

async function bridgeHealth() {
  const client = await bridgeClient();
  const health = await client.health();
  return { ...health, endpoint: client.endpoint };
}

/**
 * Strumień odpowiedzi leci portem, nie pojedynczymi wiadomościami.
 *
 * Zapytanie musi wyjść z service workera, a nie z content scriptu: fetch
 * w content scripcie ma origin strony (np. https://meet.google.com), który
 * most odrzuca — wpuszcza wyłącznie `chrome-extension://`.
 */
chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== MSG.ASSISTANT_PORT) return;

  const inFlight = new Map();

  port.onMessage.addListener(async (message) => {
    if (message?.type !== 'ask') return;
    const { id, prompt } = message;
    if (!id || !prompt) return;

    try {
      const client = await bridgeClient();
      inFlight.set(id, client);
      port.postMessage({ type: 'start', id });
      const result = await client.ask({
        id,
        prompt,
        onDelta: (text) => {
          try {
            port.postMessage({ type: 'delta', id, text });
          } catch {
            /* port zamknięty — nadawca zniknął */
          }
        },
      });
      port.postMessage({ type: 'done', id, text: result.text, durationMs: result.durationMs });
    } catch (error) {
      try {
        port.postMessage({ type: 'error', id, error: String(error?.message ?? error) });
      } catch {
        /* port zamknięty */
      }
    } finally {
      inFlight.delete(id);
    }
  });

  port.onDisconnect.addListener(() => {
    for (const client of inFlight.values()) client.cancelAll();
    inFlight.clear();
  });
});

chrome.tabs.onRemoved.addListener((tabId) => {
  // Zamknięcie karty kończy też przechwytywanie audio tej karty.
  audioState()
    .then(({ running, entry }) => (running && entry?.tabId === tabId ? stopAudioCapture() : null))
    .catch(console.error)
    .finally(() =>
      autoSave(tabId)
        .catch(console.error)
        .finally(() => chrome.storage.local.remove(TAB_KEY(tabId))),
    );
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.action.setBadgeBackgroundColor({ color: '#17c964' }).catch(() => {});
});
