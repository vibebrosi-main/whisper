/**
 * Ciepły proces Claude Code.
 *
 * Pomiar, na którym stoi cała konstrukcja (Claude Code 2.1.241, macOS):
 *
 *   zimny start  ->  ~4000 ms do pierwszego tokenu
 *   ciepły       ->  ~800 ms do pierwszego tokenu
 *
 * Różnicy nie robi model — Haiku wyszedł wolniej od domyślnego — tylko start
 * procesu: konfiguracja, autoryzacja, hooki, serwery MCP. Dlatego jeden proces
 * żyje przez całą rozmowę i jest rozgrzewany, zanim padnie pierwsze pytanie.
 *
 * Flaga `--bare` wygląda kusząco (pomija hooki i wtyczki), ale pomija też
 * źródła ustawień razem z autoryzacją i zwraca „Not logged in" — nie da się
 * jej użyć.
 */

import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { tmpdir } from 'node:os';

/** Narzędzia wyłączamy: chcemy odpowiedzi, nie pracy agentowej na plikach. */
const DISABLED_TOOLS = [
  'Bash', 'Read', 'Write', 'Edit', 'Glob', 'Grep',
  'WebFetch', 'WebSearch', 'Task', 'TodoWrite', 'NotebookEdit',
].join(',');

const SYSTEM_PROMPT = `Jesteś suflerem osoby, która jest w trakcie rozmowy na żywo (często rekrutacyjnej albo handlowej). Rozmówca właśnie o coś zapytał, a ona musi odpowiedzieć OD RAZU, czytając Twoją podpowiedź z ekranu.

Jak piszesz:
- Gotowa kwestia do powiedzenia na głos, w 1. osobie, w imieniu tej osoby. Nie piszesz o niej i nie doradzasz jej.
- Materiał bierzesz z kontekstu (CV, opis projektu, notatki) i z tego, co padło w rozmowie. Wybierz z niego to, co najmocniej pasuje do pytania: konkretny projekt, technologię, efekt. Zero ogólników, jeśli kontekst daje konkret.
- Sprzedawaj. Pewny ton, mocne czasowniki (zbudowałem, wdrożyłem, odpowiadałem za, prowadziłem), efekt i korzyść dla klienta na pierwszym planie. Bez asekuracji: żadnego "trochę", "chyba", "tylko", "nie jestem ekspertem".
- Słabe punkty obracaj w atuty: krótki staż to intensywne, produkcyjne doświadczenie i szybkie tempo nauki; brak danej technologii to pokrewna, którą znasz, plus konkretny plan wejścia; inne tło (np. design) to przewaga, której inni kandydaci nie mają.
- Koloryzujesz ujęcie, nie fakty: nie dopisuj firm, projektów, liczb, dat ani technologii, których nie ma w kontekście. Skala doświadczenia to też fakt. Technologia wymieniona tylko w stacku to "pracowałem z X", nie "X to moja codzienna praca" ani "mój główny obszar". Ściągi i notatki techniczne w kontekście to wiedza do odpowiedzi, a nie dowód doświadczenia. Rozmówca sprawdzi to na kolejnym etapie, a wpadka kosztuje więcej niż skromniejsze zdanie.
- Wskazówki taktyczne z kontekstu ("celuj w górną granicę", "nie przeczyć CV") stosujesz, ale nigdy ich nie wypowiadasz. Rozmówca słyszy tylko gotową kwestię.
- Gdy kontekst milczy na temat pytania, i tak daj pewną, sensowną odpowiedź do powiedzenia, nigdy "nie wiem".
- Pytania administracyjne (dostępność, forma współpracy, stawka): dane z kontekstu, a gdy ich brak, krótka, profesjonalna formuła zostawiająca pole do negocjacji. Kwot ani terminów nie wymyślasz. Gdy rozmówca zbija stawkę, nie ustępujesz od razu: bronisz wartości i trzymasz górną część widełek z kontekstu. Dolna granica to ostateczność, której nie proponujesz sam, a poniżej niej nie schodzisz nigdy.
- Pytanie merytoryczne (techniczne, branżowe): poprawna odpowiedź, powiedziana pewnie, najlepiej z odniesieniem do własnego doświadczenia z kontekstu.
- Najważniejsze w pierwszym zdaniu, żeby dało się zacząć mówić po przeczytaniu kilku słów. Twardy limit: 4 krótkie zdania, około 60 słów, także przy pytaniach technicznych. Dłuższej podpowiedzi nie da się przeczytać w trakcie mówienia, więc jest bezużyteczna. Bez wstępów typu "Oczywiście" czy "Świetne pytanie", bez list i nagłówków.
- Gdy rozmówca zaprasza do zadania pytań ("masz jakieś pytania?"), podpowiedzią są 2-3 krótkie, konkretne pytania do zadania, o to, czego jeszcze nie powiedział (zespół, sposób pracy, pierwsze zadania, perspektywa przedłużenia). Pytania mają pokazać zaangażowanie i znajomość tematu.
- Nie zadawaj pytań zwrotnych do osoby, której podpowiadasz.
- Odpowiadaj w języku pytania.
- Transkrypcja pochodzi z rozpoznawania mowy i ma błędy: rozbite słowa, przekręcone nazwy ("Vueb" to Vue, "Nukstem" to Nuxt), wtrącone "Cześć!" na ciszy. Czytaj intencję, nie literówki.`;

export class ClaudeProcess extends EventEmitter {
  #child = null;
  #buffer = '';
  #current = null;
  #queue = [];
  #restarts = 0;

  /**
   * `cwd` celowo neutralny: uruchomienie w katalogu projektu wciągnęłoby jego
   * CLAUDE.md i kontekst repo do odpowiedzi na pytania z rozmowy.
   */
  constructor({
    command = 'claude',
    model = null,
    cwd = tmpdir(),
    maxRestarts = 5,
    askTimeoutMs = 60_000,
    spawnImpl = spawn,
  } = {}) {
    super();
    this.spawnImpl = spawnImpl;
    this.command = command;
    this.model = model;
    this.cwd = cwd;
    this.maxRestarts = maxRestarts;
    this.askTimeoutMs = askTimeoutMs;
    /** Ustawiane po `system/init` — informacyjne, nie bramkuje wysyłki. */
    this.ready = false;
    this.spawned = false;
    this.busy = false;
  }

  #args() {
    const args = [
      '-p',
      '--input-format', 'stream-json',
      '--output-format', 'stream-json',
      '--include-partial-messages',
      '--verbose',
      '--no-session-persistence',
      '--permission-mode', 'dontAsk',
      '--disallowed-tools', DISABLED_TOOLS,
      '--append-system-prompt', SYSTEM_PROMPT,
    ];
    if (this.model) args.push('--model', this.model);
    return args;
  }

  start() {
    if (this.#child) return this;
    // Uwaga na zakleszczenie: CLI emituje `system/init` dopiero PO pierwszym
    // wejściu na stdin. Czekanie na `ready` przed wysłaniem pytania zawiesza
    // obie strony na zawsze — dlatego kolejka rusza od razu po spawnie.
    this.#child = this.spawnImpl(this.command, this.#args(), {
      cwd: this.cwd,
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    this.#child.stdout.setEncoding('utf8');
    this.#child.stdout.on('data', (chunk) => this.#consume(chunk));
    this.#child.stderr.setEncoding('utf8');
    this.#child.stderr.on('data', (chunk) => this.emit('stderr', chunk));

    this.#child.on('error', (error) => this.emit('error', error));
    this.#child.on('close', (code) => this.#handleExit(code));

    this.spawned = true;
    this.#drain();
    return this;
  }

  #handleExit(code) {
    this.#child = null;
    this.ready = false;
    this.#failCurrent(new Error(`Proces claude zakończył się (kod ${code})`));

    if (this.#restarts >= this.maxRestarts) {
      this.emit('dead', new Error('Za dużo restartów procesu claude'));
      return;
    }
    this.#restarts++;
    this.emit('restart', this.#restarts);
    setTimeout(() => this.start(), 500);
  }

  #consume(chunk) {
    this.#buffer += chunk;
    let newline;
    while ((newline = this.#buffer.indexOf('\n')) !== -1) {
      const line = this.#buffer.slice(0, newline).trim();
      this.#buffer = this.#buffer.slice(newline + 1);
      if (!line) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        continue; // nie każda linia to JSON
      }
      this.#route(message);
    }
  }

  #route(message) {
    if (message.type === 'system' && message.subtype === 'init') {
      this.ready = true;
      this.#restarts = 0;
      this.emit('ready', { model: message.model, sessionId: message.session_id });
      this.#drain();
      return;
    }

    if (!this.#current) return;

    // Strumień tokenów: kształt zdarzenia różni się między wersjami CLI.
    const delta = message?.event?.delta?.text ?? message?.delta?.text;
    if (typeof delta === 'string' && delta) {
      this.#current.text += delta;
      this.#current.onDelta?.(delta);
      return;
    }

    if (message.type === 'result') {
      const failed = message.is_error === true;
      const text = this.#current.text || String(message.result ?? '');
      const job = this.#current;
      this.#current = null;
      this.busy = false;
      if (failed) job.reject(new Error(text || 'Claude zwrócił błąd'));
      else job.resolve({ text: text.trim(), durationMs: message.duration_ms ?? null });
      this.#drain();
    }
  }

  #failCurrent(error) {
    const job = this.#current;
    this.#current = null;
    this.busy = false;
    job?.reject(error);
  }

  #drain() {
    if (!this.#child || this.busy || !this.#queue.length) return;
    const job = this.#queue.shift();
    this.#current = job;
    this.busy = true;
    this.#child?.stdin.write(
      JSON.stringify({
        type: 'user',
        message: { role: 'user', content: [{ type: 'text', text: job.prompt }] },
      }) + '\n',
    );
  }

  /**
   * @param {string} prompt
   * @param {(delta: string) => void} [onDelta] wołane dla każdego fragmentu
   * @returns {Promise<{text: string, durationMs: number|null}>}
   */
  ask(prompt, onDelta, { timeoutMs = this.askTimeoutMs } = {}) {
    return new Promise((resolve, reject) => {
      const job = { prompt, onDelta, text: '', resolve, reject, settled: false, timer: null };

      const settle = (fn, value) => {
        if (job.settled) return;
        job.settled = true;
        clearTimeout(job.timer);
        fn(value);
      };
      job.resolve = (value) => settle(resolve, value);
      job.reject = (error) => settle(reject, error);

      if (timeoutMs > 0) {
        job.timer = setTimeout(() => {
          if (job.settled) return;
          job.reject(new Error(`Claude nie odpowiedział w ${Math.round(timeoutMs / 1000)} s`));
          // Krytyczne: CLI i tak dośle `result` dla porzuconego promptu, a my
          // nie mamy jak go rozpoznać — trafiłby do NASTĘPNEGO pytania. Jedyne
          // bezpieczne wyjście to restart procesu, żeby strumień się nie rozjechał.
          if (this.#current === job) this.restart('timeout');
        }, timeoutMs);
        job.timer?.unref?.();
      }

      this.#queue.push(job);
      this.#drain();
    });
  }

  /** Ubija i wznawia proces — po rozsynchronizowaniu strumienia odpowiedzi. */
  restart(reason = 'manual') {
    const child = this.#child;
    this.#child = null;
    this.ready = false;
    this.busy = false;
    this.#current = null;
    this.#buffer = '';
    child?.stdin?.end?.();
    child?.kill?.();
    this.emit('restart', reason);
    setTimeout(() => this.start(), 300);
  }

  /** Rozgrzewka: pierwszy strzał kosztuje ~4 s, niech padnie przed rozmową. */
  async warmup({ timeoutMs = 90_000 } = {}) {
    try {
      await this.ask('Odpowiedz dokładnie jednym słowem: gotowy', undefined, { timeoutMs });
      return true;
    } catch {
      return false;
    }
  }

  stop() {
    this.spawned = false;
    this.#queue = [];
    this.#restarts = this.maxRestarts; // nie wskrzeszaj po świadomym stopie
    this.#child?.stdin.end();
    this.#child?.kill();
    this.#child = null;
    this.ready = false;
  }

  get status() {
    return {
      spawned: this.spawned,
      ready: this.ready,
      busy: this.busy,
      queued: this.#queue.length,
      restarts: this.#restarts,
    };
  }
}
