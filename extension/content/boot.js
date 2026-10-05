/**
 * Bootstrap content scriptu.
 *
 * Content scripty MV3 nie ładują się jako moduły ES, więc ten klasyczny plik
 * robi jedną rzecz: dynamicznie importuje właściwy moduł z zasobów rozszerzenia.
 * Dzięki temu rdzeń (`src/**`) jest zwykłym ESM — tym samym, który importują
 * testy w node i narzędzia CLI. Zero bundlera, jedno źródło prawdy.
 */
(async () => {
  try {
    const url = chrome.runtime.getURL('content/main.js');
    const module = await import(url);
    await module.boot();
  } catch (error) {
    console.error('[call-whisper] nie udało się wystartować:', error);
  }
})();
