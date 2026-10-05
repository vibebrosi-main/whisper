#!/usr/bin/env node
/**
 * Renderuje zapisaną sesję (.json z eksportu) do Markdownu.
 * Ten sam rdzeń, którego używa rozszerzenie — dowód, że warstwa transkryptu
 * jest niezależna od przeglądarki.
 *
 *   node tools/render.mjs sesja.json > notatka.md
 *   node tools/render.mjs sesja.json --out notatka.md --locale en --absolute
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { Session } from '../extension/src/core/session.js';

const HELP = `call-whisper render

  node tools/render.mjs <sesja.json> [opcje]

Opcje:
  --out <plik>       zapisz do pliku (domyślnie stdout)
  --locale <pl|en>   język nagłówków (domyślnie pl)
  --absolute         timestampy jako godzina zegarowa zamiast offsetu
  --no-frontmatter   bez bloku YAML
  --no-stats         bez tabeli uczestników
  -h, --help         ta pomoc
`;

function parseArgs(argv) {
  const options = { locale: 'pl', absoluteTimestamps: false, frontmatter: true, stats: true, out: null };
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '-h' || arg === '--help') return { help: true, options, positional };
    else if (arg === '--out') options.out = argv[++i];
    else if (arg === '--locale') options.locale = argv[++i];
    else if (arg === '--absolute') options.absoluteTimestamps = true;
    else if (arg === '--no-frontmatter') options.frontmatter = false;
    else if (arg === '--no-stats') options.stats = false;
    else positional.push(arg);
  }
  return { help: false, options, positional };
}

const { help, options, positional } = parseArgs(process.argv.slice(2));

if (help || positional.length !== 1) {
  process.stdout.write(HELP);
  process.exit(help ? 0 : 1);
}

let data;
try {
  data = JSON.parse(readFileSync(positional[0], 'utf8'));
} catch (error) {
  console.error(`Nie mogę wczytać ${positional[0]}: ${error.message}`);
  process.exit(1);
}

const session = Session.fromJSON(data);
const markdown = session.toMarkdown(options);

if (options.out) {
  writeFileSync(options.out, markdown, 'utf8');
  console.error(`Zapisano ${options.out} (${session.segments.length} wypowiedzi)`);
} else {
  process.stdout.write(markdown);
}
