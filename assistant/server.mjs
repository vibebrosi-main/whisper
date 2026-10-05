#!/usr/bin/env node
/**
 * Most między rozszerzeniem a lokalnym CLI Claude Code.
 *
 * Rozszerzenie Chrome nie może uruchamiać procesów, więc most działa jako
 * mały serwer HTTP na pętli zwrotnej. Odpowiedzi lecą strumieniem (chunked,
 * JSON-lines), bo liczy się czas do pierwszego tokenu, nie do ostatniego —
 * przy ciepłym procesie to ~1 s zamiast ~4 s.
 *
 * Świadomie bez WebSocketów: te wymagałyby zależności `ws` albo ręcznej
 * implementacji ramkowania RFC 6455, a strumieniowany `fetch` daje to samo.
 *
 *   node assistant/server.mjs [--port 8787] [--model <id>] [--token <sekret>]
 */

import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { ClaudeProcess } from './claude-process.mjs';

const DEFAULTS = { port: 8787, host: '127.0.0.1', model: null, token: null };

function parseArgs(argv) {
  const options = { ...DEFAULTS };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--port') options.port = Number(argv[++i]);
    else if (argv[i] === '--model') options.model = argv[++i];
    else if (argv[i] === '--token') options.token = argv[++i];
    else if (argv[i] === '--host') options.host = argv[++i];
    else if (argv[i] === '-h' || argv[i] === '--help') options.help = true;
  }
  return options;
}

/**
 * Do mostu może pukać każda strona otwarta w przeglądarce, więc wpuszczamy
 * wyłącznie rozszerzenia — plus token, jeśli został ustawiony.
 */
export function isAllowedOrigin(origin) {
  if (!origin) return true; // narzędzia CLI, curl — nie mają Origin
  return origin.startsWith('chrome-extension://') || origin.startsWith('moz-extension://');
}

function cors(res, origin) {
  res.setHeader('Access-Control-Allow-Origin', origin ?? '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
  res.setHeader('Vary', 'Origin');
}

function readBody(req, limitBytes = 256 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limitBytes) {
        reject(new Error('Żądanie za duże'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'));
      } catch (error) {
        reject(new Error(`Niepoprawny JSON: ${error.message}`));
      }
    });
    req.on('error', reject);
  });
}

export function createBridge({ claude, token = null } = {}) {
  const stats = { asked: 0, failed: 0, startedAt: Date.now() };

  const server = createServer(async (req, res) => {
    const origin = req.headers.origin;
    cors(res, origin);

    if (req.method === 'OPTIONS') {
      res.writeHead(204).end();
      return;
    }

    if (!isAllowedOrigin(origin)) {
      res.writeHead(403, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'origin-not-allowed' }));
      return;
    }

    if (token) {
      const provided = req.headers.authorization?.replace(/^Bearer\s+/i, '');
      if (provided !== token) {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'bad-token' }));
        return;
      }
    }

    if (req.method === 'GET' && req.url.startsWith('/health')) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, claude: claude.status, stats, tokenRequired: Boolean(token) }));
      return;
    }

    if (req.method === 'POST' && req.url.startsWith('/ask')) {
      await handleAsk(req, res);
      return;
    }

    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'not-found' }));
  });

  async function handleAsk(req, res) {
    let payload;
    try {
      payload = await readBody(req);
    } catch (error) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: error.message }));
      return;
    }

    const prompt = String(payload?.prompt ?? '').trim();
    if (!prompt) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'brak-promptu' }));
      return;
    }

    const id = payload.id ?? randomUUID();
    stats.asked++;

    // Strumień JSON-lines: klient renderuje tokeny, zanim odpowiedź się skończy.
    res.writeHead(200, {
      'Content-Type': 'application/x-ndjson; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      'X-Accel-Buffering': 'no',
    });

    const send = (message) => {
      if (!res.writableEnded) res.write(`${JSON.stringify(message)}\n`);
    };
    send({ type: 'start', id, at: Date.now() });

    let aborted = false;
    req.on('close', () => (aborted = true));

    try {
      const result = await claude.ask(prompt, (delta) => {
        if (!aborted) send({ type: 'delta', id, text: delta });
      });
      send({ type: 'done', id, text: result.text, durationMs: result.durationMs });
    } catch (error) {
      stats.failed++;
      send({ type: 'error', id, error: String(error?.message ?? error) });
    } finally {
      if (!res.writableEnded) res.end();
    }
  }

  return { server, stats };
}

/* ---------- uruchomienie z linii poleceń ---------- */

const isMain = process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop());
if (isMain) {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(`call-whisper — most do Claude Code

  node assistant/server.mjs [opcje]

Opcje:
  --port <n>       port nasłuchu (domyślnie 8787)
  --model <id>     model dla CLI (domyślnie: twój domyślny)
  --token <sekret> wymagaj nagłówka Authorization: Bearer <sekret>
  --host <adres>   domyślnie 127.0.0.1 — nie wystawiaj tego na świat
`);
    process.exit(0);
  }

  const claude = new ClaudeProcess({ model: options.model });
  claude.on('restart', (n) => console.error(`[most] restart procesu claude (${n})`));
  claude.on('dead', (error) => {
    console.error(`[most] proces claude nie wstaje: ${error.message}`);
    process.exit(1);
  });
  claude.start();

  const { server } = createBridge({ claude, token: options.token });
  server.listen(options.port, options.host, async () => {
    console.error(`[most] nasłuchuję na http://${options.host}:${options.port}`);
    if (options.token) console.error('[most] token wymagany');
    console.error('[most] rozgrzewam proces claude…');
    const t0 = Date.now();
    const ok = await claude.warmup();
    console.error(
      ok
        ? `[most] gotowy po ${Date.now() - t0} ms — kolejne pytania ~1 s do pierwszego tokenu`
        : '[most] rozgrzewka nie powiodła się — sprawdź, czy jesteś zalogowany (claude /login)',
    );
  });

  const shutdown = () => {
    console.error('\n[most] zamykam');
    claude.stop();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1000);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}
