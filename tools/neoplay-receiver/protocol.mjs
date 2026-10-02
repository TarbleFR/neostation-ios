// NeoPlay v1: one muxed H.264/AAC timeline, not two independently drifting clocks.
export const VERSION = 1;
export const MAX_PACKET = 4 * 1024 * 1024;
export const MAX_BUFFERED = 8 * 1024 * 1024;
export function displayLimits(input = {}) {
  const integer = (v, fallback, max) => Number.isFinite(v) && v >= 2 ? Math.min(max, Math.floor(v / 2) * 2) : fallback;
  return { width: integer(input.width, 1280, 7680), height: integer(input.height, 720, 4320), maxWidth: 1920, maxHeight: 1080, fps: 60 };
}
export function fit(sourceWidth, sourceHeight, targetWidth, targetHeight) {
  if (![sourceWidth, sourceHeight, targetWidth, targetHeight].every(n => Number.isFinite(n) && n > 0)) throw new RangeError('Invalid dimensions');
  const scale = Math.min(targetWidth / sourceWidth, targetHeight / sourceHeight);
  const width = sourceWidth * scale, height = sourceHeight * scale;
  return { width, height, x: (targetWidth - width) / 2, y: (targetHeight - height) / 2 };
}
export function validatePacket(bytes) {
  if (!bytes || bytes.length < 9 || bytes.length > MAX_PACKET || ![1, 2].includes(bytes[0])) throw new Error('Invalid media packet');
  return bytes[0];
}
export function mp4Mime(bytes) {
  // avcC contains the exact encoder profile/compatibility/level. Do not guess it.
  const b = new Uint8Array(bytes);
  for (let i = 4; i + 8 < b.length; i++) {
    if (b[i] === 97 && b[i+1] === 118 && b[i+2] === 99 && b[i+3] === 67 && b[i+4] === 1) {
      const size = new DataView(b.buffer, b.byteOffset + i - 4, 4).getUint32(0);
      if (size < 12 || i - 4 + size > b.length) continue;
      const avc = Array.from(b.slice(i+5, i+8), v => v.toString(16).padStart(2, '0')).join('');
      return `video/mp4; codecs="avc1.${avc}, mp4a.40.2"`;
    }
  }
  throw new Error('Missing AVC configuration');
}
