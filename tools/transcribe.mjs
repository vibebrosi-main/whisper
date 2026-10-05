#!/usr/bin/env node
/**
 * Sprawdzenie klucza i modelu Groqa bez ładowania rozszerzenia.
 *
 * Używa tego samego klienta, którego używa wtyczka — jeśli tutaj działa,
 * w przeglądarce też zadziała.
 *
 *   node tools/transcribe.mjs nagranie.wav
 *   node tools/transcribe.mjs nagranie.wav --model whisper-large-v3 --lang pl
 *
 * Klucz czytany z .env (GROQ_API_KEY) albo ze zmiennej środowiskowej.
 */

import { readFileSync, existsSync } from 'node:fs';
import { basename } from 'node:path';
import { GroqTranscriber, GROQ_MODELS, DEFAULT_MODEL } from '../extension/src/adapters/audio/groq.js';

const HELP = `call-whisper transcribe

  node tools/transcribe.mjs <plik audio> [opcje]

Opcje:
  --model <id>   ${GROQ_MODELS.map((m) => m.id).join(' | ')}
  --lang <kod>   ISO-639-1, np. pl (domyślnie: autodetekcja)
  --segments     wypisz segmenty ze znacznikami czasu
  -h, --help
`;

/** Minimalny czytnik .env — bez dokładania zależności. */
function loadEnv(path = '.env') {
  if (!existsSync(path)) return {};
  const out = {};
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const match = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/i.exec(line);
    if (match) out[match[1]] = match[2].replace(/^["']|["']$/g, '');
  }
  return out;
}

const args = process.argv.slice(2);
if (!args.length || args.includes('-h') || args.includes('--help')) {
  process.stdout.write(HELP);
  process.exit(args.length ? 0 : 1);
}

const options = { model: DEFAULT_MODEL, language: null, segments: false };
const positional = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--model') options.model = args[++i];
  else if (args[i] === '--lang') options.language = args[++i];
  else if (args[i] === '--segments') options.segments = true;
  else positional.push(args[i]);
}

const apiKey = process.env.GROQ_API_KEY ?? loadEnv().GROQ_API_KEY;
if (!apiKey) {
  console.error('Brak GROQ_API_KEY — ustaw w .env albo w środowisku.');
  process.exit(1);
}

const file = positional[0];
if (!existsSync(file)) {
  console.error(`Nie ma pliku ${file}`);
  process.exit(1);
}

const audio = readFileSync(file);
const transcriber = new GroqTranscriber({ apiKey, model: options.model, language: options.language });

const startedAt = Date.now();
try {
  const result = await transcriber.transcribe(
    audio.buffer.slice(audio.byteOffset, audio.byteOffset + audio.byteLength),
  );
  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1);
  console.error(`${basename(file)} — ${options.model} — ${elapsed}s`);

  if (options.segments) {
    for (const segment of result.segments) {
      console.log(`[${segment.start.toFixed(1)}s–${segment.end.toFixed(1)}s] ${segment.text}`);
    }
  } else {
    console.log(result.text);
  }
} catch (error) {
  console.error(`Błąd: ${error.message}${error.code ? ` (${error.code})` : ''}`);
  process.exit(1);
}
