import { test } from 'node:test';
import assert from 'node:assert/strict';
import { resolveBackendPlan, BACKENDS } from '../extension/src/adapters/audio/backend-plan.js';

test('Groq z kluczem wybiera Groqa', () => {
  const plan = resolveBackendPlan({ backend: 'groq', groq: { apiKey: 'gsk_x' } });
  assert.deepEqual(plan, { backend: BACKENDS.GROQ, warnings: [], needsSpeechModel: false });
});

test('Groq bez klucza spada na Web Speech i mówi dlaczego', () => {
  const plan = resolveBackendPlan({ backend: 'groq', groq: {} });
  assert.equal(plan.backend, BACKENDS.WEBSPEECH);
  assert.deepEqual(plan.warnings, ['groq-no-key']);
  assert.equal(plan.needsSpeechModel, true, 'Web Speech potrzebuje modelu SODA');
});

test('whisper.cpp z adresem wybiera lokalny backend', () => {
  const plan = resolveBackendPlan({ backend: 'whisper-local', whisper: { url: 'http://127.0.0.1:8899' } });
  assert.deepEqual(plan, { backend: BACKENDS.WHISPER_LOCAL, warnings: [], needsSpeechModel: false });
});

test('whisper.cpp bez adresu spada na Web Speech', () => {
  const plan = resolveBackendPlan({ backend: 'whisper-local', whisper: {} });
  assert.equal(plan.backend, BACKENDS.WEBSPEECH);
  assert.deepEqual(plan.warnings, ['whisper-no-url']);
});

test('brak wejścia daje bezpieczny domyślny bez wybuchu', () => {
  // Regresja: brakująca nazwa w destrukturyzacji dawała „whisper is not defined".
  assert.doesNotThrow(() => resolveBackendPlan());
  assert.equal(resolveBackendPlan().backend, BACKENDS.WEBSPEECH);
  assert.equal(resolveBackendPlan({ backend: 'whisper-local' }).warnings[0], 'whisper-no-url');
  assert.equal(resolveBackendPlan({ backend: 'nieznany' }).backend, BACKENDS.WEBSPEECH);
});
