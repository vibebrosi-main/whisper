import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname;

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) walk(path, out);
    else if (entry.endsWith('.js') || entry.endsWith('.mjs')) out.push(path);
  }
  return out;
}

/**
 * Każdy moduł rdzenia musi dać się zaimportować bez API przeglądarki.
 *
 * `node --check` waliduje tylko składnię — nie wyłapie odwołania do
 * niezdefiniowanej nazwy ani zepsutego importu. Ten test łapie oba na
 * poziomie modułu.
 */
test('wszystkie moduły src/ importują się bez chrome.* i bez błędów', async () => {
  const files = walk(join(ROOT, 'extension', 'src'));
  assert.ok(files.length > 10, `znaleziono tylko ${files.length} modułów`);

  const failures = [];
  for (const file of files) {
    try {
      await import(file);
    } catch (error) {
      failures.push(`${relative(ROOT, file)}: ${error.message}`);
    }
  }
  assert.deepEqual(failures, [], `moduły nie do zaimportowania:\n${failures.join('\n')}`);
});

test('moduły narzędziowe (assistant, asr) też się importują', async () => {
  const failures = [];
  for (const file of [join(ROOT, 'assistant', 'claude-process.mjs'), join(ROOT, 'assistant', 'server.mjs')]) {
    try {
      await import(file);
    } catch (error) {
      failures.push(`${relative(ROOT, file)}: ${error.message}`);
    }
  }
  assert.deepEqual(failures, []);
});

test('każdy eksportowany moduł ma co eksportować', async () => {
  const files = walk(join(ROOT, 'extension', 'src'));
  const empty = [];
  for (const file of files) {
    const module = await import(file);
    if (Object.keys(module).length === 0) empty.push(relative(ROOT, file));
  }
  assert.deepEqual(empty, [], 'moduły bez eksportów są martwym kodem');
});
