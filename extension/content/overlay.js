/**
 * Nakładka asystenta na stronie rozmowy.
 *
 * Cały interfejs siedzi w Shadow DOM: wstrzykujemy się w cudzą stronę
 * (Meet, Zoom, Teams), więc bez izolacji jej CSS zniszczyłby nasz i odwrotnie.
 *
 * Nakładka nie odpytuje mostu sama — robi to service worker przez port.
 * Fetch z content scriptu miałby origin strony, który most odrzuca.
 */

import { MSG } from '../src/core/messages.js';
import { AssistantSession } from '../src/core/assistant.js';

const STYLE = `
:host { all: initial; }
.panel {
  position: fixed;
  right: 16px;
  bottom: 16px;
  z-index: 2147483647;
  width: 340px;
  max-height: 60vh;
  display: flex;
  flex-direction: column;
  font-family: Inter, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  font-size: 13px;
  line-height: 1.45;
  color: #ECEDEE;
  background: #18181b;
  border-radius: 14px;
  box-shadow: 0 0 30px rgb(0 0 0 / 0.35), 0 30px 60px rgb(0 0 0 / 0.45);
  overflow: hidden;
}
.panel[data-collapsed='true'] .body { display: none; }
.head {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 12px;
  border-bottom: 1px solid rgb(255 255 255 / 0.1);
  cursor: pointer;
  user-select: none;
}
.dot { width: 8px; height: 8px; border-radius: 999px; background: #71717a; flex: none; }
.dot[data-state='ok'] { background: #17c964; }
.dot[data-state='busy'] { background: #006FEE; animation: pulse 1s ease-in-out infinite; }
.dot[data-state='down'] { background: #f31260; }
@keyframes pulse { 50% { opacity: 0.3; } }
.title { font-weight: 600; flex: 1; }
.hint { font-size: 11px; color: #a1a1aa; }
.chev { color: #a1a1aa; font-size: 11px; }
.body { overflow-y: auto; padding: 8px; display: flex; flex-direction: column; gap: 8px; }
.body::-webkit-scrollbar { width: 6px; }
.body::-webkit-scrollbar-thumb { background: #3f3f46; border-radius: 999px; }
.empty { color: #71717a; font-size: 12px; padding: 16px 8px; text-align: center; }
.item { background: #27272a; border-radius: 10px; padding: 8px 10px; }
.q { font-size: 12px; color: #d4d4d8; display: flex; gap: 6px; }
.q b { color: #f4f4f5; font-weight: 600; }
.a { margin-top: 6px; white-space: pre-wrap; word-break: break-word; }
.a[data-status='pending'] { color: #71717a; font-style: italic; }
.a[data-status='error'] { color: #f54180; }
.a[data-status='streaming']::after {
  content: '▍'; color: #006FEE; animation: blink 1s steps(2, start) infinite;
}
@keyframes blink { to { opacity: 0; } }
.meta { margin-top: 4px; font-size: 10px; color: #52525b; }
.actions { display: flex; gap: 6px; margin-top: 6px; }
button {
  font: inherit; font-size: 11px; padding: 4px 8px; border: none; border-radius: 8px;
  background: #3f3f46; color: #e4e4e7; cursor: pointer;
}
button:hover { opacity: 0.8; }
.composer {
  display: flex;
  align-items: flex-end;
  gap: 6px;
  padding: 8px;
  border-top: 1px solid rgb(255 255 255 / 0.1);
}
.panel[data-collapsed='true'] .composer { display: none; }
.composer textarea {
  flex: 1;
  font: inherit;
  resize: none;
  min-height: 34px;
  max-height: 96px;
  padding: 8px 10px;
  border: 1px solid rgb(255 255 255 / 0.1);
  border-radius: 10px;
  background: #27272a;
  color: #ECEDEE;
  outline: none;
}
.composer textarea:focus { border-color: #006FEE; }
.composer textarea::placeholder { color: #71717a; }
.send {
  flex: none;
  width: 34px;
  height: 34px;
  padding: 0;
  font-size: 14px;
  background: #006FEE;
  color: #fff;
}
.send:disabled { background: #3f3f46; color: #71717a; cursor: default; opacity: 1; }
`;

const EMPTY_HINT = 'Czekam na pytanie w rozmowie — albo wpisz swoje poniżej.';
/** Ile pikseli wysokości pola przed pojawieniem się paska przewijania (~4 wiersze). */
const INPUT_MAX_HEIGHT = 96;
/** Etykieta pytań wpisanych ręcznie — odróżnia je od tych złapanych w transkrypcji. */
const MANUAL_SPEAKER = 'Ty';

export class AssistantOverlay {
  #session = new AssistantSession({ maxItems: 20 });
  #port = null;
  #root = null;
  #host = null;
  #collapsed = false;

  constructor({ onAsk } = {}) {
    this.onAsk = onAsk;
    this.bridgeState = 'unknown';
  }

  mount(doc = document) {
    if (this.#host) return this;

    this.#host = doc.createElement('div');
    this.#host.id = 'call-whisper-assistant';
    this.#root = this.#host.attachShadow({ mode: 'open' });

    const style = doc.createElement('style');
    style.textContent = STYLE;

    this.panel = doc.createElement('div');
    this.panel.className = 'panel';
    this.panel.innerHTML = `
      <div class="head">
        <span class="dot"></span>
        <span class="title">Asystent</span>
        <span class="hint"></span>
        <span class="chev">▾</span>
      </div>
      <div class="body"><div class="empty">${EMPTY_HINT}</div></div>
      <div class="composer">
        <textarea rows="1" placeholder="Wpisz lub wklej pytanie…" aria-label="Pytanie do asystenta"></textarea>
        <button class="send" type="button" title="Wyślij (Enter)" disabled>↑</button>
      </div>
    `;

    this.dot = this.panel.querySelector('.dot');
    this.hint = this.panel.querySelector('.hint');
    this.body = this.panel.querySelector('.body');
    this.chev = this.panel.querySelector('.chev');
    this.panel.querySelector('.head').addEventListener('click', () => this.toggle());
    this.#wireComposer();

    this.#root.append(style, this.panel);
    doc.documentElement.append(this.#host);
    this.#connect();
    return this;
  }

  toggle() {
    this.#collapsed = !this.#collapsed;
    this.panel.dataset.collapsed = String(this.#collapsed);
    this.chev.textContent = this.#collapsed ? '▸' : '▾';
  }

  unmount() {
    this.#port?.disconnect();
    this.#port = null;
    this.#host?.remove();
    this.#host = null;
  }

  #connect() {
    try {
      this.#port = chrome.runtime.connect({ name: MSG.ASSISTANT_PORT });
    } catch {
      this.setBridgeState('down', 'brak połączenia');
      return;
    }

    this.#port.onMessage.addListener((message) => {
      const { id } = message;
      if (message.type === 'delta') {
        this.#session.append(id, message.text);
        this.setBridgeState('busy', 'odpowiada…');
      } else if (message.type === 'done') {
        this.#session.complete(id, { answer: message.text, durationMs: message.durationMs });
        this.setBridgeState('ok', 'gotowy');
      } else if (message.type === 'error') {
        this.#session.fail(id, message.error);
        this.setBridgeState('down', 'most nie odpowiada');
      }
      this.render();
    });

    this.#port.onDisconnect.addListener(() => {
      this.#port = null;
      this.setBridgeState('down', 'most rozłączony');
      this.render();
    });
  }

  setBridgeState(state, hint = '') {
    this.bridgeState = state;
    if (this.dot) this.dot.dataset.state = state;
    if (this.hint) this.hint.textContent = hint;
  }

  #wireComposer() {
    this.input = this.panel.querySelector('textarea');
    this.sendButton = this.panel.querySelector('.send');
    const composer = this.panel.querySelector('.composer');

    // Strona pod spodem trzyma skróty klawiszowe na całym dokumencie (Meet
    // wycisza mikrofon na „d"). Bez zatrzymania zdarzeń pisanie w polu
    // sterowałoby rozmową — dlatego klawisze nie opuszczają nakładki.
    for (const type of ['keydown', 'keyup', 'keypress']) {
      composer.addEventListener(type, (event) => event.stopPropagation());
    }

    this.input.addEventListener('input', () => this.#refreshComposer());
    this.input.addEventListener('keydown', (event) => {
      // Enter wysyła, Shift+Enter łamie wiersz. W trakcie składania znaku
      // (IME, martwe klawisze) Enter zatwierdza kandydata, nie pytanie.
      if (event.key !== 'Enter' || event.shiftKey || event.isComposing) return;
      event.preventDefault();
      this.#submit();
    });
    this.sendButton.addEventListener('click', () => this.#submit());
  }

  /** Wysokość pola i stan przycisku idą za treścią. */
  #refreshComposer() {
    const text = this.input.value.trim();
    this.sendButton.disabled = !text;
    this.input.style.height = 'auto';
    this.input.style.height = `${Math.min(this.input.scrollHeight, INPUT_MAX_HEIGHT)}px`;
  }

  #submit() {
    const question = this.input.value.trim();
    if (!question) return;
    this.input.value = '';
    this.#refreshComposer();
    this.input.focus();

    // Bez `onAsk` nakładka nie ma dostępu do transkrypcji, więc pytanie idzie
    // do mostu samo — gorszy kontekst, ale wciąż działa (tak chodzi podgląd).
    if (this.onAsk) this.onAsk(question);
    else this.ask({ question, speaker: MANUAL_SPEAKER, prompt: question, auto: false });
  }

  /** Nowe pytanie — z transkrypcji albo wpisane ręcznie. Od razu leci do Claude'a. */
  ask({ question, speaker, prompt, auto = true }) {
    const item = this.#session.add({ question, speaker, auto });
    this.render();
    this.body.scrollTop = 0;

    if (!this.#port) {
      this.#session.fail(item.id, 'Most nie działa — uruchom `npm run assistant`');
      this.render();
      return item;
    }
    this.#port.postMessage({ type: 'ask', id: item.id, prompt });
    this.setBridgeState('busy', 'pytam…');
    return item;
  }

  render() {
    if (!this.body) return;
    const items = this.#session.items;

    if (!items.length) {
      this.body.replaceChildren(this.#el('div', 'empty', EMPTY_HINT));
      return;
    }

    const fragment = document.createDocumentFragment();
    for (const item of items.slice().reverse()) {
      const card = this.#el('div', 'item');

      const question = this.#el('div', 'q');
      if (item.speaker) question.append(this.#el('b', null, `${item.speaker}:`));
      question.append(this.#el('span', null, item.question));

      const answer = this.#el('div', 'a', item.status === 'pending' ? 'myślę…' : item.answer || '');
      answer.dataset.status = item.status;
      if (item.status === 'error') answer.textContent = item.error;

      card.append(question, answer);
      if (item.durationMs) card.append(this.#el('div', 'meta', `${(item.durationMs / 1000).toFixed(1)} s`));
      fragment.append(card);
    }
    this.body.replaceChildren(fragment);
  }

  #el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }
}
