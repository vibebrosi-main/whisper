import { DEFAULT_SETTINGS } from '/extension/src/core/settings.js';

/**
 * Harness podglądu popupu: wstrzykuje prawdziwy markup popup.html do strony,
 * podstawia atrapę API Chrome i uruchamia prawdziwy popup.js.
 * Dzięki temu UI da się oglądać i poprawiać bez przeładowywania rozszerzenia.
 */

const START = Date.now() - 1_531_000;

const SEGMENTS = [
  ['Anna Kowalska', 'Cześć wszystkim, zaczynamy standup. Anka, lecisz pierwsza?', 12_000, 18_000],
  ['Anna Kowalska', 'Tylko przypomnę, że o dwunastej mamy demo dla klienta.', 19_500, 24_000],
  ['Jan Nowak', 'Jasne. Wczoraj domknąłem migrację bazy, dzisiaj biorę się za raporty.', 26_000, 34_000],
  ['Jan Nowak', 'Blokuje mnie tylko dostęp do stagingu, Marta obiecała dosłać klucze.', 35_000, 41_000],
  ['Marta Zielińska', 'Klucze wysłałam rano na maila, sprawdź spam.', 43_000, 47_500],
  ['Marta Zielińska', 'Poza tym kończę projekt nowego onboardingu, jutro pokażę makiety.', 48_000, 55_000],
  ['Anna Kowalska', 'Super. To jeszcze tylko ryzyka i kończymy.', 57_000, 61_000],
  ['Jan Nowak', 'Z mojej strony jedno: jeśli staging nie ruszy do jutra, demo', 63_000, null],
];

function buildSegments(limit = SEGMENTS.length) {
  return SEGMENTS.slice(0, limit).map(([speaker, text, offset, end], index) => ({
    id: `s${index + 1}`,
    speaker,
    text,
    startedAt: START + offset,
    endedAt: START + (end ?? offset + 4000),
    offsetMs: offset,
    final: end !== null,
  }));
}

function buildSpeakers(segments) {
  const map = new Map();
  for (const segment of segments) {
    const row = map.get(segment.speaker) ?? { name: segment.speaker, segments: 0, words: 0 };
    row.segments++;
    row.words += segment.text.split(' ').length;
    map.set(segment.speaker, row);
  }
  return [...map.values()];
}

const SCENARIOS = {
  live: () => {
    const segments = buildSegments();
    return {
      onMeet: true,
      state: {
        ok: true,
        running: true,
        captions: 'on',
        captionRoot: true,
        inCall: true,
        meta: { title: 'Standup zespołu', source: 'google-meet', startedAt: START },
        startedAt: START,
        durationMs: Date.now() - START,
        segmentCount: segments.length,
        wordCount: buildSpeakers(segments).reduce((acc, s) => acc + s.words, 0),
        speakers: buildSpeakers(segments),
        recent: segments,
      },
    };
  },
  'captions-off': () => {
    const base = SCENARIOS.live();
    return {
      onMeet: true,
      state: {
        ...base.state,
        captions: 'off',
        captionRoot: false,
        segmentCount: 0,
        wordCount: 0,
        speakers: [],
        recent: [],
        durationMs: 42_000,
      },
    };
  },
  idle: () => ({ onMeet: false, state: null }),
  settings: () => SCENARIOS.live(),
  audio: () => SCENARIOS.live(),
};

/** Sesja trybu audio: mówcy z diaryzacji, nie z DOM-u Meeta. */
const AUDIO_SEGMENTS = [
  ['Rozmówca 1', 'Dzień dobry, słyszymy się dobrze?', 8_000, 12_000],
  ['Ty', 'Tak, wszystko gra. Zaczynajmy.', 13_500, 17_000],
  ['Rozmówca 2', 'Ja mam jedno pytanie do wczorajszych liczb.', 19_000, 25_000],
  ['Rozmówca 1', 'Jasne, przejdę przez nie po kolei.', 26_500, 31_000],
  ['Osoba obok 1', 'Dorzucę tylko kontekst z naszej strony.', 33_000, null],
];

function audioSession(startedAt) {
  return {
    meta: { title: 'Zoom — planowanie kwartału', source: 'audio', startedAt },
    segments: AUDIO_SEGMENTS.map(([speaker, text, offset, end], index) => ({
      id: `a${index + 1}`,
      speaker,
      text,
      startedAt: startedAt + offset,
      endedAt: startedAt + (end ?? offset + 3000),
      offsetMs: offset,
      final: end !== null,
    })),
  };
}

let scenario = 'live';
// Atrapa ustawień wychodzi od prawdziwych domyślnych — inaczej rozjeżdża się
// z popupem przy każdym nowym polu.
let settings = { ...DEFAULT_SETTINGS };

function currentScenario() {
  return SCENARIOS[scenario]();
}

/** Atrapa chrome.* — tylko te wywołania, których używa popup.js. */
globalThis.chrome = {
  tabs: {
    query: async () => {
      const { onMeet } = currentScenario();
      return [{ id: 1, url: onMeet ? 'https://meet.google.com/abc-defg-hij' : 'https://example.com' }];
    },
    sendMessage: async () => {
      const { state } = currentScenario();
      if (!state) throw new Error('brak content scriptu');
      return state;
    },
  },
  runtime: {
    sendMessage: async (message) => {
      if (message.type === 'cw:get-settings') return { ok: true, settings };
      if (message.type === 'cw:set-settings') {
        settings = { ...settings, ...message.patch };
        return { ok: true, settings };
      }
      if (message.type === 'cw:audio-state') {
        return {
          ok: true,
          running: scenario === 'audio',
          entry: {
            tabId: 1,
            session: audioSession(START),
            status: { mode: 'audio', warnings: scenario === 'audio' ? [] : ['mic-denied'] },
          },
        };
      }
      if (message.type === 'cw:get-last') {
        const segments = buildSegments(4);
        return {
          ok: true,
          last: {
            session: {
              meta: {
                title: 'Retro sprintu 24',
                source: 'google-meet',
                startedAt: START - 86_400_000,
                endedAt: START - 86_400_000 + 2_760_000,
              },
              segments,
            },
          },
        };
      }
      return { ok: true };
    },
  },
};

async function mount() {
  const html = await fetch('/extension/popup/popup.html').then((r) => r.text());
  const parsed = new DOMParser().parseFromString(html, 'text/html');
  document.getElementById('frame').replaceChildren(...parsed.body.children);
  await import('/extension/popup/popup.js');
}

function setTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
}

document.addEventListener('click', (event) => {
  const themeButton = event.target.closest('[data-theme-set]');
  if (themeButton) return setTheme(themeButton.dataset.themeSet);

  const scenarioButton = event.target.closest('[data-scenario]');
  if (!scenarioButton) return;
  scenario = scenarioButton.dataset.scenario;

  if (scenario === 'settings') {
    document.getElementById('settings-toggle')?.click();
    return;
  }

  document.getElementById('panel-settings').hidden = true;
  document.getElementById('panel-live').hidden = false;

  // Tryb przełączamy prawdziwym przyciskiem popupu — popup trzyma własną
  // kopię ustawień, więc podmiana atrapy nic by nie dała.
  const wantedMode = scenario === 'audio' ? 'audio' : 'meet';
  const modeButton = document.querySelector(`#mode-switch [data-mode="${wantedMode}"]`);
  if (modeButton?.getAttribute('aria-pressed') !== 'true') modeButton?.click();
});

setTheme('light');
mount();
