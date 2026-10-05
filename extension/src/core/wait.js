/**
 * Odpytywanie z limitem czasu.
 *
 * Powstało z konkretnego błędu: `chrome.offscreen.createDocument()` wraca, gdy
 * dokument istnieje, ale jego skrypt jest modułem ES i ładuje się dalej
 * asynchronicznie. Wysłanie wiadomości od razu trafia w pustkę — listener nie
 * jest jeszcze zarejestrowany. Trzeba poczekać, aż dokument sam się odezwie.
 */

/**
 * @param {() => Promise<boolean>|boolean} check zwraca true, gdy warunek spełniony
 * @param {{timeoutMs?: number, intervalMs?: number, sleep?: (ms: number) => Promise<void>, now?: () => number}} options
 * @returns {Promise<boolean>} czy doczekaliśmy się w limicie
 */
export async function waitFor(check, {
  timeoutMs = 3000,
  intervalMs = 100,
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  now = () => Date.now(),
} = {}) {
  const deadline = now() + timeoutMs;
  for (;;) {
    let ok = false;
    try {
      ok = await check();
    } catch {
      ok = false;
    }
    if (ok) return true;
    if (now() >= deadline) return false;
    await sleep(intervalMs);
  }
}
