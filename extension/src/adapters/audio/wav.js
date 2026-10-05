/**
 * Kodowanie PCM do WAV. Groq przyjmuje pliki, nie strumienie, więc każdą
 * wypowiedź trzeba opakować w kontener. 16-bit PCM mono to najprostszy format,
 * który rozumie każdy dekoder — a Groq i tak downsampluje do 16 kHz mono.
 */

const HEADER_BYTES = 44;

function writeAscii(view, offset, text) {
  for (let i = 0; i < text.length; i++) view.setUint8(offset + i, text.charCodeAt(i));
}

/** Float32 [-1, 1] -> int16 z obcięciem zakresu. */
function toInt16(sample) {
  const clamped = Math.max(-1, Math.min(1, sample));
  return clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff;
}

/**
 * @param {Float32Array} samples
 * @param {{sampleRate?: number, channels?: number}} [options]
 * @returns {ArrayBuffer} kompletny plik WAV
 */
export function encodeWav(samples, { sampleRate = 16_000, channels = 1 } = {}) {
  const bytesPerSample = 2;
  const dataBytes = samples.length * bytesPerSample;
  const buffer = new ArrayBuffer(HEADER_BYTES + dataBytes);
  const view = new DataView(buffer);

  writeAscii(view, 0, 'RIFF');
  view.setUint32(4, 36 + dataBytes, true); // rozmiar pliku - 8
  writeAscii(view, 8, 'WAVE');

  writeAscii(view, 12, 'fmt ');
  view.setUint32(16, 16, true); // długość bloku fmt
  view.setUint16(20, 1, true); // 1 = PCM bez kompresji
  view.setUint16(22, channels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * channels * bytesPerSample, true); // bajtów na sekundę
  view.setUint16(32, channels * bytesPerSample, true); // wyrównanie bloku
  view.setUint16(34, 8 * bytesPerSample, true);

  writeAscii(view, 36, 'data');
  view.setUint32(40, dataBytes, true);

  let offset = HEADER_BYTES;
  for (let i = 0; i < samples.length; i++) {
    view.setInt16(offset, toInt16(samples[i]), true);
    offset += bytesPerSample;
  }
  return buffer;
}

/** Długość audio w ms dla danej liczby próbek. */
export function durationMs(sampleCount, sampleRate = 16_000) {
  return (sampleCount / sampleRate) * 1000;
}
