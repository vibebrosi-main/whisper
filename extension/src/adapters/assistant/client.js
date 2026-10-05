/**
 * Klient mostu do Claude Code.
 *
 * Czyta strumień JSON-lines przez `fetch` — bez WebSocketów, bo te wymagałyby
 * zależności po stronie serwera, a strumieniowana odpowiedź HTTP daje to samo.
 *
 * Pomiar, który dyktuje sposób użycia: przy ciepłym procesie pierwszy token
 * przychodzi po ~1 s, ale pierwsze pytanie po dłuższej przerwie potrafi zająć
 * ~4,5 s. Dlatego pytania wysyłamy w momencie WYKRYCIA w transkrypcji, a nie
 * gdy ktoś kliknie — odpowiedź ma czekać, zanim ktokolwiek na nią spojrzy.
 */

const DEFAULT_ENDPOINT = 'http://127.0.0.1:8787';

export class BridgeClient {
  #controllers = new Map();

  constructor({ endpoint = DEFAULT_ENDPOINT, token = null, fetchImpl = globalThis.fetch?.bind(globalThis) } = {}) {
    this.endpoint = endpoint.replace(/\/+$/, '');
    this.token = token;
    this.fetchImpl = fetchImpl;
  }

  #headers(extra = {}) {
    const headers = { 'Content-Type': 'application/json', ...extra };
    if (this.token) headers.Authorization = `Bearer ${this.token}`;
    return headers;
  }

  /** @returns {Promise<{ok: boolean, claude?: object, error?: string}>} */
  async health(timeoutMs = 2000) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await this.fetchImpl(`${this.endpoint}/health`, {
        headers: this.#headers(),
        signal: controller.signal,
      });
      if (!response.ok) return { ok: false, error: `HTTP ${response.status}` };
      return await response.json();
    } catch (error) {
      return { ok: false, error: error?.name === 'AbortError' ? 'timeout' : String(error?.message ?? error) };
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * Zadaje pytanie i strumieniuje odpowiedź.
   * @param {{id: string, prompt: string, onDelta?: (text: string) => void}} request
   * @returns {Promise<{text: string, durationMs: number|null}>}
   */
  async ask({ id, prompt, onDelta }) {
    const controller = new AbortController();
    this.#controllers.set(id, controller);

    try {
      const response = await this.fetchImpl(`${this.endpoint}/ask`, {
        method: 'POST',
        headers: this.#headers(),
        body: JSON.stringify({ id, prompt }),
        signal: controller.signal,
      });

      if (!response.ok) {
        const detail = await response.text().catch(() => '');
        throw new Error(`Most odpowiedział ${response.status}${detail ? `: ${detail.slice(0, 120)}` : ''}`);
      }
      if (!response.body) throw new Error('Most nie zwrócił strumienia');

      return await this.#consume(response.body, onDelta);
    } finally {
      this.#controllers.delete(id);
    }
  }

  async #consume(body, onDelta) {
    const reader = body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    let text = '';
    let durationMs = null;

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      let newline;
      while ((newline = buffer.indexOf('\n')) !== -1) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (!line) continue;

        let message;
        try {
          message = JSON.parse(line);
        } catch {
          continue;
        }

        if (message.type === 'delta') {
          text += message.text;
          onDelta?.(message.text);
        } else if (message.type === 'done') {
          text = message.text ?? text;
          durationMs = message.durationMs ?? null;
        } else if (message.type === 'error') {
          throw new Error(message.error);
        }
      }
    }
    return { text: text.trim(), durationMs };
  }

  /** Przerywa konkretne pytanie — np. gdy rozmowa poszła dalej. */
  cancel(id) {
    this.#controllers.get(id)?.abort();
    this.#controllers.delete(id);
  }

  cancelAll() {
    for (const controller of this.#controllers.values()) controller.abort();
    this.#controllers.clear();
  }
}
