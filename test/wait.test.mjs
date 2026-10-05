import { test } from 'node:test';
import assert from 'node:assert/strict';
import { waitFor } from '../extension/src/core/wait.js';

/** Sterowany zegar — testy nie mogą zależeć od realnego czasu. */
function clock() {
  let t = 0;
  return { now: () => t, sleep: async (ms) => { t += ms; } };
}

test('zwraca true, gdy warunek jest spełniony od razu', async () => {
  const c = clock();
  let calls = 0;
  const ok = await waitFor(() => { calls++; return true; }, { ...c });
  assert.equal(ok, true);
  assert.equal(calls, 1, 'bez zbędnego czekania');
});

test('odpytuje, aż warunek zostanie spełniony', async () => {
  const c = clock();
  let calls = 0;
  const ok = await waitFor(() => ++calls >= 4, { ...c, intervalMs: 50 });
  assert.equal(ok, true);
  assert.equal(calls, 4);
  assert.equal(c.now(), 150, 'trzy przerwy po 50 ms');
});

test('poddaje się po przekroczeniu limitu', async () => {
  const c = clock();
  const ok = await waitFor(() => false, { ...c, timeoutMs: 300, intervalMs: 100 });
  assert.equal(ok, false);
  assert.ok(c.now() >= 300);
});

test('wyjątek w sprawdzeniu to po prostu „jeszcze nie"', async () => {
  const c = clock();
  let calls = 0;
  const ok = await waitFor(
    () => {
      if (++calls < 3) throw new Error('jeszcze nie gotowe');
      return true;
    },
    { ...c, intervalMs: 10 },
  );
  assert.equal(ok, true);
  assert.equal(calls, 3);
});

test('obsługuje sprawdzenia asynchroniczne', async () => {
  const c = clock();
  let calls = 0;
  const ok = await waitFor(async () => ++calls >= 2, { ...c, intervalMs: 25 });
  assert.equal(ok, true);
  assert.equal(c.now(), 25);
});
