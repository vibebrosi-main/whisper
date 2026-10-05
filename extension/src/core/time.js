/**
 * Formatowanie czasu. Zero zależności, działa w node i w przeglądarce.
 */

const pad = (n, width = 2) => String(Math.floor(Math.abs(n))).padStart(width, '0');

/** Offset od początku sesji jako HH:MM:SS (godziny nieograniczone). */
export function formatOffset(ms) {
  const total = Math.max(0, Math.round((Number(ms) || 0) / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return `${pad(h)}:${pad(m)}:${pad(s)}`;
}

/** Czas trwania w formacie zwięzłym: 42m 11s / 1h 02m / 8s */
export function formatDuration(ms) {
  const total = Math.max(0, Math.round((Number(ms) || 0) / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h) return `${h}h ${pad(m)}m`;
  if (m) return `${m}m ${pad(s)}s`;
  return `${s}s`;
}

export function formatLocalDate(ts) {
  const d = new Date(ts);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export function formatLocalTime(ts, withSeconds = true) {
  const d = new Date(ts);
  const base = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  return withSeconds ? `${base}:${pad(d.getSeconds())}` : base;
}

export function formatLocalDateTime(ts, withSeconds = true) {
  return `${formatLocalDate(ts)} ${formatLocalTime(ts, withSeconds)}`;
}

/** Stempel do nazwy pliku: 2026-08-23_1015 */
export function filenameStamp(ts) {
  const d = new Date(ts);
  return `${formatLocalDate(ts)}_${pad(d.getHours())}${pad(d.getMinutes())}`;
}
