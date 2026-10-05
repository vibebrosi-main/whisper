/** Protokół komunikacji popup <-> content script <-> service worker. */
export const MSG = {
  /** popup -> content: daj aktualny stan sesji */
  GET_STATE: 'cw:get-state',
  /** popup -> content: sterowanie nagrywaniem */
  START: 'cw:start',
  STOP: 'cw:stop',
  RESET: 'cw:reset',
  /** popup -> content: kliknij przycisk napisów w Meecie */
  ENABLE_CAPTIONS: 'cw:enable-captions',
  /** popup -> content: pełny JSON sesji (do eksportu) */
  GET_SESSION: 'cw:get-session',
  /** content -> sw: zapisz migawkę sesji */
  PERSIST: 'cw:persist',
  /** popup -> sw: pobierz plik */
  DOWNLOAD: 'cw:download',
  /** popup/sw: ustawienia */
  GET_SETTINGS: 'cw:get-settings',
  SET_SETTINGS: 'cw:set-settings',
  /** sw -> popup: ostatnia zapisana sesja (gdy nie ma content scriptu) */
  GET_LAST: 'cw:get-last',

  /* --- tryb audio (rozpoznawanie po głosie) --- */
  /** popup -> sw: zacznij przechwytywać audio karty (wymaga gestu użytkownika) */
  AUDIO_START: 'cw:audio-start',
  AUDIO_STOP: 'cw:audio-stop',
  /** popup -> sw: stan nagrywania audio */
  AUDIO_STATE: 'cw:audio-state',
  /** popup -> sw: otwórz stronę nadania zgody na mikrofon */
  OPEN_MIC_PERMISSION: 'cw:open-mic-permission',
  /** popup -> sw: otwórz ustawienia Napisów na żywo (pobierają model mowy) */
  OPEN_CAPTIONS_SETTINGS: 'cw:open-captions-settings',
  /** sw -> offscreen: sterowanie przechwytywaniem (z polem target: 'offscreen') */
  OFFSCREEN_START: 'cw:offscreen-start',
  OFFSCREEN_STOP: 'cw:offscreen-stop',
  OFFSCREEN_STATUS: 'cw:offscreen-status',

  /* --- asystent (Claude Code przez lokalny most) --- */
  /** popup -> sw: sprawdź, czy most odpowiada */
  BRIDGE_HEALTH: 'cw:bridge-health',
  /** popup -> sw: czy lokalny whisper.cpp odpowiada */
  WHISPER_HEALTH: 'cw:whisper-health',
  /** content -> sw: nazwa portu do strumieniowania odpowiedzi */
  ASSISTANT_PORT: 'cw:assistant',
  /** sw -> content: nowe pytanie wykryte / stan asystenta */
  ASSISTANT_STATE: 'cw:assistant-state',
};
