#!/usr/bin/env node
/**
 * Uruchamia lokalny `whisper-server` (whisper.cpp) z sensownymi domyślnymi.
 *
 * Model trzymany jest w pamięci między żądaniami — to ta sama lekcja, co przy
 * moście do Claude Code: koszt startu przewyższa koszt samej inferencji.
 * Zimne wywołanie `whisper-cli` płaci ~400 ms na załadowanie modelu; ciepły
 * serwer nie płaci nic.
 *
 * Zmierzone na Apple M4, 5 s polskiego audio, round-trip HTTP:
 *   ggml-small           396 ms
 *   ggml-large-v3-turbo  ~1,4 s
 *
 *   node asr/whisper.mjs [--model small] [--port 8899] [--lang pl]
 */

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const MODELS_DIR = join(homedir(), '.cache', 'whisper-models');
const BASE_URL = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main';

/** `small` jest domyślny: 4x szybszy od large-v3-turbo przy tej samej jakości po polsku. */
const DEFAULTS = { model: 'small', port: 8899, lang: 'pl', threads: 8, host: '127.0.0.1' };

function parseArgs(argv) {
  const options = { ...DEFAULTS };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--model') options.model = argv[++i];
    else if (argv[i] === '--port') options.port = Number(argv[++i]);
    else if (argv[i] === '--lang') options.lang = argv[++i];
    else if (argv[i] === '--threads') options.threads = Number(argv[++i]);
    else if (argv[i] === '-h' || argv[i] === '--help') options.help = true;
  }
  return options;
}

const options = parseArgs(process.argv.slice(2));
if (options.help) {
  process.stdout.write(`call-whisper — lokalny serwer whisper.cpp

  node asr/whisper.mjs [opcje]

Opcje:
  --model <nazwa>  small (domyślnie) | base | medium | large-v3-turbo
  --port <n>       domyślnie 8899
  --lang <kod>     domyślnie pl
  --threads <n>    domyślnie 8

Wymaga whisper.cpp: brew install whisper-cpp
`);
  process.exit(0);
}

const modelPath = join(MODELS_DIR, `ggml-${options.model}.bin`);

if (!existsSync(modelPath)) {
  console.error(`Brak modelu ${options.model}. Pobierz go:

  mkdir -p ${MODELS_DIR}
  curl -L -o ${modelPath} \\
    ${BASE_URL}/ggml-${options.model}.bin
`);
  mkdirSync(MODELS_DIR, { recursive: true });
  process.exit(1);
}

const child = spawn(
  'whisper-server',
  [
    '-m', modelPath,
    '--host', options.host,
    '--port', String(options.port),
    '-t', String(options.threads),
    '-l', options.lang,
  ],
  { stdio: 'inherit' },
);

child.on('error', (error) => {
  if (error.code === 'ENOENT') {
    console.error('Nie znaleziono `whisper-server`. Zainstaluj: brew install whisper-cpp');
  } else {
    console.error(`Nie mogę uruchomić whisper-server: ${error.message}`);
  }
  process.exit(1);
});

console.error(`[whisper] model ${options.model}, http://${options.host}:${options.port}/inference`);

const shutdown = () => {
  child.kill();
  process.exit(0);
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
