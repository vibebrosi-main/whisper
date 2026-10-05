/**
 * Generator ikon rozszerzenia. Minimalny enkoder PNG na node:zlib —
 * żeby repo nie ciągnęło żadnej zależności tylko po to, żeby narysować kwadrat.
 *
 *   node tools/make-icons.mjs
 */

import { deflateSync } from 'node:zlib';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const OUT_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'extension', 'icons');

const BG = [0x00, 0x6f, 0xee, 0xff]; // HeroUI primary
const FG = [0xff, 0xff, 0xff, 0xff];
const TRANSPARENT = [0, 0, 0, 0];

/** Wysokości słupków fali (ułamek wysokości ikony), środkowane w pionie. */
const BARS = [0.28, 0.52, 0.86, 0.62, 0.34];

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buffer) {
  let c = -1;
  for (const byte of buffer) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

function encodePng(size, pixelAt) {
  const stride = size * 4;
  const raw = Buffer.alloc((stride + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (stride + 1)] = 0; // filtr: none
    for (let x = 0; x < size; x++) {
      const [r, g, b, a] = pixelAt(x, y);
      const offset = y * (stride + 1) + 1 + x * 4;
      raw[offset] = r;
      raw[offset + 1] = g;
      raw[offset + 2] = b;
      raw[offset + 3] = a;
    }
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

/** Zaokrąglony kwadrat + fala dźwiękowa. */
function iconPixel(size) {
  const radius = size * 0.22;
  const barWidth = Math.max(1, Math.round(size * 0.09));
  const gap = Math.max(1, Math.round(size * 0.055));
  const totalWidth = BARS.length * barWidth + (BARS.length - 1) * gap;
  const startX = (size - totalWidth) / 2;

  const insideRoundedRect = (x, y) => {
    const cx = Math.min(Math.max(x, radius), size - radius);
    const cy = Math.min(Math.max(y, radius), size - radius);
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2;
  };

  return (px, py) => {
    const x = px + 0.5;
    const y = py + 0.5;
    if (!insideRoundedRect(x, y)) return TRANSPARENT;

    for (let i = 0; i < BARS.length; i++) {
      const left = startX + i * (barWidth + gap);
      if (x < left || x > left + barWidth) continue;
      const height = BARS[i] * size;
      const top = (size - height) / 2;
      if (y >= top && y <= top + height) return FG;
    }
    return BG;
  };
}

mkdirSync(OUT_DIR, { recursive: true });
for (const size of [16, 48, 128]) {
  const png = encodePng(size, iconPixel(size));
  writeFileSync(join(OUT_DIR, `icon-${size}.png`), png);
  console.log(`icons/icon-${size}.png  ${png.length} B`);
}
