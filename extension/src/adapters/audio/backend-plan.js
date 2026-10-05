/**
 * Wybór backendu transkrypcji — czysta decyzja, bez API przeglądarki.
 *
 * Wyciągnięte z `offscreen.js` po realnym błędzie: brakująca nazwa w
 * destrukturyzacji (`whisper is not defined`) przeszła przez `node --check`,
 * bo to poprawna składnia, tylko niezdefiniowany identyfikator. Dokument
 * offscreen jest nietestowalny (żyje na `chrome.*`), więc decyzje muszą
 * mieszkać tutaj, gdzie da się je sprawdzić.
 */

export const BACKENDS = { WEBSPEECH: 'webspeech', GROQ: 'groq', WHISPER_LOCAL: 'whisper-local' };

/**
 * @param {{backend?: string, groq?: {apiKey?: string}, whisper?: {url?: string}}} input
 * @returns {{backend: string, warnings: string[], needsSpeechModel: boolean}}
 */
export function resolveBackendPlan({ backend = BACKENDS.WEBSPEECH, groq = {}, whisper = {} } = {}) {
  const warnings = [];

  if (backend === BACKENDS.GROQ) {
    if (groq?.apiKey) {
      return { backend: BACKENDS.GROQ, warnings, needsSpeechModel: false };
    }
    // Bez klucza Groq nie ruszy — spadamy na Web Speech i mówimy dlaczego.
    warnings.push('groq-no-key');
    return { backend: BACKENDS.WEBSPEECH, warnings, needsSpeechModel: true };
  }

  if (backend === BACKENDS.WHISPER_LOCAL) {
    if (whisper?.url) {
      return { backend: BACKENDS.WHISPER_LOCAL, warnings, needsSpeechModel: false };
    }
    warnings.push('whisper-no-url');
    return { backend: BACKENDS.WEBSPEECH, warnings, needsSpeechModel: true };
  }

  return { backend: BACKENDS.WEBSPEECH, warnings, needsSpeechModel: true };
}
