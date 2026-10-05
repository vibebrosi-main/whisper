/**
 * Przechwytywanie i analiza audio.
 *
 * Dwa niezależne źródła, każde z własnym rozpoznawaniem i własnym
 * diaryzatorem, oba piszące do jednej sesji:
 *
 *   karta (tabCapture) -> zdalni uczestnicy -> „Rozmówca 1..N"
 *   mikrofon           -> ty i osoby obok  -> „Ty", „Osoba obok N"
 *
 * Rozdzielenie źródeł daje darmowy i bezbłędny podział na „ja" vs „oni" —
 * dopiero wewnątrz każdego źródła potrzebna jest diaryzacja po głosie.
 */

import { Session } from '../src/core/session.js';
import { AudioAdapter } from '../src/adapters/audio/index.js';
import { GroqAdapter } from '../src/adapters/audio/groq-adapter.js';
import { StreamingWhisperAdapter } from '../src/adapters/audio/streaming-adapter.js';
import { resolveBackendPlan, BACKENDS } from '../src/adapters/audio/backend-plan.js';
import { Framer } from '../src/adapters/audio/framer.js';
import { Diarizer } from '../src/adapters/audio/diarizer.js';
import { MfccExtractor } from '../src/adapters/audio/features.js';
import { availability, isSupported, resolveMode, ModelWatcher } from '../src/adapters/audio/asr.js';
import { MSG } from '../src/core/messages.js';

/** Częstotliwość analizy — modele mowy i MFCC pracują na 16 kHz. */
const ANALYSIS_SAMPLE_RATE = 16_000;
const PERSIST_THROTTLE_MS = 1500;

let capture = null;

/** Jedno źródło audio: strumień -> ramki -> diaryzacja + ASR. */
class SourceCapture {
  constructor({ source, stream, store, lang, epochMs, processLocally, backend, groq, whisper, onChange, onError }) {
    this.source = source;
    this.stream = stream;
    this.lang = lang;
    this.epochMs = epochMs;
    this.processLocally = processLocally;
    this.backend = backend;
    this.onError = onError;

    const extractor = new MfccExtractor({ sampleRate: ANALYSIS_SAMPLE_RATE });
    this.extractor = extractor;
    const diarizer = new Diarizer({ sampleRate: ANALYSIS_SAMPLE_RATE, extractor });

    if (backend === 'whisper-local') {
      this.adapter = new StreamingWhisperAdapter({
        store,
        source,
        epochMs,
        diarizer,
        endpoint: whisper?.url,
        language: lang.split('-')[0],
        sampleRate: ANALYSIS_SAMPLE_RATE,
        onChange,
        onError,
      });
    } else this.adapter =
      backend === 'groq'
        ? new GroqAdapter({
            store,
            source,
            epochMs,
            diarizer,
            apiKey: groq.apiKey,
            model: groq.model,
            // Groq chce ISO-639-1 ('pl'), nie pełnego taga BCP-47 ('pl-PL').
            language: lang.split('-')[0],
            sampleRate: ANALYSIS_SAMPLE_RATE,
            onChange,
            onError,
          })
        : new AudioAdapter({
            store,
            source,
            lang,
            processLocally,
            diarizer,
            onChange,
            onError,
          });

    this.framer = new Framer({
      frameSize: extractor.frameSize,
      hopSize: extractor.hopSize,
      sampleRate: ANALYSIS_SAMPLE_RATE,
      epochMs,
      onFrame: (frame, tMs) => this.adapter.pushFrame(frame, tMs),
    });
  }

  async start() {
    const track = this.stream.getAudioTracks()[0];
    if (!track) throw new Error(`Źródło ${this.source} nie ma ścieżki audio`);

    this.analysisContext = new AudioContext({ sampleRate: ANALYSIS_SAMPLE_RATE });
    await this.analysisContext.audioWorklet.addModule(chrome.runtime.getURL('offscreen/pcm-worklet.js'));

    const input = this.analysisContext.createMediaStreamSource(this.stream);
    this.worklet = new AudioWorkletNode(this.analysisContext, 'cw-pcm');
    this.worklet.port.onmessage = (event) => this.framer.push(event.data);
    input.connect(this.worklet);
    // Worklet nic nie odtwarza, ale bez podpięcia do grafu Chrome go uśpi.
    this.worklet.connect(this.analysisContext.destination);

    this.track = track;
    this.adapter.start(track);
  }

  /** Przełącza rozpoznawanie na lokalne/chmurowe bez zrywania przechwytywania. */
  switchMode(processLocally) {
    if (this.backend === 'groq') return;
    if (this.processLocally === processLocally) return;
    this.processLocally = processLocally;
    this.adapter.recognizer.stop();
    this.adapter.recognizer.processLocally = processLocally;
    this.adapter.recognizer.start(this.track);
  }

  async stop() {
    await this.adapter.stop();
    this.worklet?.port && (this.worklet.port.onmessage = null);
    this.worklet?.disconnect();
    this.analysisContext?.close().catch(() => {});
    for (const track of this.stream.getTracks()) track.stop();
  }

  get status() {
    return { ...this.adapter.status, source: this.source };
  }
}

/** Cała sesja nagrywania: karta + opcjonalnie mikrofon. */
class Capture {
  #lastPersist = 0;
  #sources = [];

  constructor({ tabId, title, url, lang }) {
    this.tabId = tabId;
    this.lang = lang;
    this.epochMs = Date.now();
    this.session = new Session({
      title,
      source: AudioAdapter.id,
      url,
      startedAt: this.epochMs,
    });
    this.warnings = [];
  }

  async start({ streamId, withMic, allowCloud = false, backend = BACKENDS.WEBSPEECH, groq = {}, whisper = {} }) {
    this.whisper = whisper ?? {};
    this.groq = groq ?? {};

    const plan = resolveBackendPlan({ backend, groq: this.groq, whisper: this.whisper });
    this.backend = plan.backend;
    this.warnings.push(...plan.warnings);

    if (!plan.needsSpeechModel) {
      this.processLocally = this.backend === BACKENDS.WHISPER_LOCAL;
      this.recognition = this.backend;
      if (streamId) await this.#addTabSource(streamId);
      if (withMic) await this.#addMicSource();
      if (!this.#sources.length) throw new Error('Nie udało się otworzyć żadnego źródła audio');
      return;
    }

    if (!isSupported()) throw new Error('Ta przeglądarka nie ma Web Speech API');

    const mode = await resolveMode({ lang: this.lang, allowCloud });
    this.processLocally = mode.processLocally;
    this.recognition = mode.reason;

    if (mode.reason === 'model-missing') this.warnings.push('model-missing');
    if (mode.reason === 'cloud') this.warnings.push('using-cloud');
    if (mode.availability === 'unsupported') this.warnings.push('no-api');

    if (streamId) await this.#addTabSource(streamId);
    if (withMic) await this.#addMicSource();
    if (!this.#sources.length) throw new Error('Nie udało się otworzyć żadnego źródła audio');

    // Jeśli model dojedzie w trakcie (użytkownik włączy Napisy na żywo),
    // przechodzimy na lokalny bez restartu nagrywania.
    if (!this.processLocally || mode.reason === 'model-missing') {
      this.watcher = new ModelWatcher({
        lang: this.lang,
        onReady: () => this.#useLocalModel(),
      }).start();
    }
  }

  #useLocalModel() {
    this.processLocally = true;
    this.recognition = 'local';
    this.warnings = this.warnings.filter((w) => w !== 'model-missing' && w !== 'using-cloud');
    for (const source of this.#sources) source.switchMode(true);
    this.persist({ final: true });
  }

  async #addTabSource(streamId) {
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId } },
    });

    // tabCapture wycisza kartę — audio trzeba oddać z powrotem na głośniki,
    // inaczej użytkownik przestaje słyszeć rozmowę.
    this.playbackContext = new AudioContext();
    this.playbackContext.createMediaStreamSource(stream).connect(this.playbackContext.destination);

    await this.#addSource('tab', stream);
  }

  async #addMicSource() {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: false },
      });
      await this.#addSource('mic', stream);
    } catch (error) {
      // Brak zgody na mikrofon nie może wywalić nagrywania karty.
      this.warnings.push('mic-denied');
      console.warn('[call-whisper] mikrofon niedostępny:', error);
    }
  }

  async #addSource(source, stream) {
    const capture = new SourceCapture({
      source,
      stream,
      store: this.session.store,
      lang: this.lang,
      epochMs: this.epochMs,
      processLocally: this.processLocally,
      backend: this.backend,
      groq: this.groq ?? {},
      whisper: this.whisper ?? {},
      onChange: () => this.persist(),
      onError: (error) => console.warn(`[call-whisper] ${source}:`, error),
    });
    await capture.start();
    this.#sources.push(capture);
  }

  persist({ final = false } = {}) {
    const now = Date.now();
    if (!final && now - this.#lastPersist < PERSIST_THROTTLE_MS) return;
    this.#lastPersist = now;
    chrome.runtime
      .sendMessage({
        type: MSG.PERSIST,
        tabId: this.tabId,
        session: this.session.toJSON(),
        status: this.status,
        final,
      })
      .catch(() => {});
  }

  async stop() {
    this.watcher?.stop();
    await Promise.all(this.#sources.map((source) => source.stop()));
    this.#sources = [];
    this.playbackContext?.close().catch(() => {});
    this.session.end();
    this.persist({ final: true });
  }

  get status() {
    return {
      running: this.#sources.length > 0,
      mode: 'audio',
      lang: this.lang,
      recognition: this.recognition ?? 'none',
      warnings: this.warnings,
      errors: [...new Set(this.#sources.map((s) => s.status.error).filter(Boolean))],
      sources: this.#sources.map((s) => s.status),
      speakers: this.session.store.speakers.length,
      segmentCount: this.session.segments.length,
    };
  }
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.target !== 'offscreen') return false;

  switch (message.type) {
    case MSG.OFFSCREEN_START:
      (async () => {
        try {
          await capture?.stop();
          capture = new Capture(message);
          await capture.start(message);
          capture.persist({ final: true });
          sendResponse({ ok: true, status: capture.status });
        } catch (error) {
          capture = null;
          sendResponse({ ok: false, error: String(error?.message ?? error) });
        }
      })();
      return true;

    case MSG.OFFSCREEN_STOP:
      (async () => {
        try {
          await capture?.stop();
        } finally {
          capture = null;
        }
        sendResponse({ ok: true });
      })();
      return true;

    // Służy też jako handshake: service worker czeka na tę odpowiedź, zanim
    // wyśle OFFSCREEN_START — moduł ES ładuje się po utworzeniu dokumentu.
    case MSG.OFFSCREEN_STATUS:
      sendResponse({ ok: true, status: capture?.status ?? null });
      return false;

    default:
      return false;
  }
});
