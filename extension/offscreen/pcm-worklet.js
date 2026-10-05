/**
 * AudioWorkletProcessor: zbiera surowe próbki i przesyła je paczkami.
 *
 * Świadomie nie liczy tu nic więcej — wątek audio ma twardy budżet czasowy
 * (128 próbek co ~8 ms) i zgubiona ramka to dziura w transkrypcji. MFCC i
 * klastrowanie robimy w wątku głównym.
 */

/** 100 ms przy 16 kHz — kompromis między liczbą wiadomości a opóźnieniem. */
const CHUNK_SAMPLES = 1600;

class PcmProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buffer = new Float32Array(CHUNK_SAMPLES);
    this.filled = 0;
  }

  process(inputs) {
    const channel = inputs[0]?.[0];
    if (!channel) return true;

    let offset = 0;
    while (offset < channel.length) {
      const take = Math.min(this.buffer.length - this.filled, channel.length - offset);
      this.buffer.set(channel.subarray(offset, offset + take), this.filled);
      this.filled += take;
      offset += take;

      if (this.filled === this.buffer.length) {
        const chunk = this.buffer.slice();
        this.port.postMessage(chunk, [chunk.buffer]);
        this.filled = 0;
      }
    }
    return true;
  }
}

registerProcessor('cw-pcm', PcmProcessor);
