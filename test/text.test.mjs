import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalize, reconcile, overlapLength, commonPrefixLength } from '../extension/src/core/text.js';

test('normalize zbija białe znaki i usuwa znaki zerowej szerokości', () => {
  assert.equal(normalize('  ala \n\t ma   kota ​'), 'ala ma kota');
  assert.equal(normalize(null), '');
});

test('overlapLength znajduje najdłuższy sufiks/prefiks', () => {
  assert.equal(overlapLength('ala ma kota', 'ma kota i psa'), 7);
  assert.equal(overlapLength('abc', 'xyz'), 0);
});

test('commonPrefixLength', () => {
  assert.equal(commonPrefixLength('dzień dobry', 'dzień dobyr'), 9);
  assert.equal(commonPrefixLength('', 'abc'), 0);
});

test('reconcile: wzrost strumienia', () => {
  assert.equal(reconcile('Cześć', 'Cześć wszystkim'), 'Cześć wszystkim');
  assert.equal(reconcile('Cześć wszystkim', 'Cześć wszystkim, zaczynamy'), 'Cześć wszystkim, zaczynamy');
});

test('reconcile: poprawka końcówki przy wspólnym początku', () => {
  const prev = 'zaczynamy dzisiejsze spotkanie o godzinie';
  const next = 'zaczynamy dzisiejsze spotkanie o godzinie dziesiątej';
  assert.equal(reconcile(prev, next), next);
  assert.equal(
    reconcile('mamy trzy punkty do omówenia', 'mamy trzy punkty do omówienia'),
    'mamy trzy punkty do omówienia',
  );
});

test('reconcile: przewijane okno doklejamy bez duplikatu', () => {
  assert.equal(
    reconcile('to jest pierwsze zdanie i drugie', 'i drugie oraz trzecie'),
    'to jest pierwsze zdanie i drugie oraz trzecie',
  );
});

test('reconcile: brak nowej treści nie psuje tekstu', () => {
  const text = 'krótka wypowiedź';
  assert.equal(reconcile(text, text), text);
  assert.equal(reconcile(text, 'krótka'), text);
});

test('reconcile: rozłączne zdania są doklejane ze spacją', () => {
  assert.equal(reconcile('pierwsze zdanie.', 'zupełnie inny wątek'), 'pierwsze zdanie. zupełnie inny wątek');
});

test('reconcile: puste wejścia', () => {
  assert.equal(reconcile('', 'abc'), 'abc');
  assert.equal(reconcile('abc', ''), 'abc');
});

test('reconcile jest stabilny przy powtarzanych migawkach', () => {
  const snapshots = ['dobrze', 'dobrze to', 'dobrze to jest', 'dobrze to jest plan', 'dobrze to jest plan na dziś'];
  let acc = '';
  for (const s of snapshots) acc = reconcile(acc, s);
  for (const s of snapshots) acc = reconcile(acc, s);
  assert.equal(acc, 'dobrze to jest plan na dziś');
});
