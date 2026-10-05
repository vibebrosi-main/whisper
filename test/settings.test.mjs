import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sanitizeSettings, DEFAULT_SETTINGS, loadSettings, saveSettings, SETTINGS_KEY } from '../extension/src/core/settings.js';

/** Atrapa chrome.storage.local. */
function fakeStorage(initial = {}) {
  let data = { ...initial };
  return {
    get: async (key) => (key ? { [key]: data[key] } : { ...data }),
    set: async (patch) => {
      data = { ...data, ...patch };
    },
    dump: () => data,
  };
}

test('sanitizeSettings uzupełnia braki i odsiewa śmieci', () => {
  const result = sanitizeSettings({ autoStart: 0, nieistniejace: 'x', silenceMs: '4000' });
  assert.equal(result.autoStart, false);
  assert.equal(result.silenceMs, 4000);
  assert.equal(result.locale, DEFAULT_SETTINGS.locale);
  assert.ok(!('nieistniejace' in result));
});

test('sanitizeSettings pilnuje dozwolonych języków i liczb dodatnich', () => {
  assert.equal(sanitizeSettings({ locale: 'de' }).locale, 'pl');
  assert.equal(sanitizeSettings({ locale: 'en' }).locale, 'en');
  assert.equal(sanitizeSettings({ silenceMs: -50 }).silenceMs, 0);
  assert.equal(sanitizeSettings({ silenceMs: 'abc' }).silenceMs, DEFAULT_SETTINGS.silenceMs);
});

test('loadSettings bez storage zwraca domyślne', async () => {
  assert.deepEqual(await loadSettings(null), { ...DEFAULT_SETTINGS });
});

test('saveSettings scala patch z aktualnym stanem', async () => {
  const storage = fakeStorage();
  await saveSettings({ locale: 'en' }, storage);
  const after = await saveSettings({ autoStart: false }, storage);
  assert.equal(after.locale, 'en');
  assert.equal(after.autoStart, false);
  assert.equal(after.frontmatter, true);
  assert.deepEqual(storage.dump()[SETTINGS_KEY], after);
});
