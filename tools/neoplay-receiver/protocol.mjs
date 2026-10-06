// NeoPlay wire protocols, shared by the Node relay and the browser page.
// v1 (kinds 1, 2): fMP4 initialization + media segments, one muxed H.264/AAC
//   timeline, played through MediaSource. Kept for old receivers and as the
//   fallback when WebCodecs is unavailable.
// v2 (kinds 3, 4, 5): one H.264 access unit per picture and raw PCM, played
//   through WebCodecs and an AudioWorklet on one sample-accurate clock. The
//   sender selects v2 when `ready` carries `frames: true`.
export const VERSION = 1;
export const MAX_PACKET = 4 * 1024 * 1024;
export const MAX_BUFFERED = 8 * 1024 * 1024;
export const KIND = Object.freeze({ INIT: 1, SEGMENT: 2, CONFIG: 3, VIDEO: 4, AUDIO: 5 });
const MINIMUM = { 1: 9, 2: 9, 3: 17, 4: 11, 5: 13 };
export function displayLimits(input = {}) {
  const integer = (v, fallback, max) => Number.isFinite(v) && v >= 2 ? Math.min(max, Math.floor(v / 2) * 2) : fallback;
  const frames = input.frames === true;
  // A v2 receiver decodes the native iPhone picture and scales it to its stage
  // (a 4K monitor shows the full capture, never a 1080p downscale); MediaSource
  // playback keeps the 1080p ceiling it was validated with.
  return { width: integer(input.width, 1280, 7680), height: integer(input.height, 720, 4320), maxWidth: frames ? 7680 : 1920, maxHeight: frames ? 4320 : 1080, fps: 60, frames };
}
export function fit(sourceWidth, sourceHeight, targetWidth, targetHeight) {
  if (![sourceWidth, sourceHeight, targetWidth, targetHeight].every(n => Number.isFinite(n) && n > 0)) throw new RangeError('Invalid dimensions');
  const scale = Math.min(targetWidth / sourceWidth, targetHeight / sourceHeight);
  const width = sourceWidth * scale, height = sourceHeight * scale;
  return { width, height, x: (targetWidth - width) / 2, y: (targetHeight - height) / 2 };
}
export function validatePacket(bytes) {
  if (!bytes || bytes.length > MAX_PACKET) throw new Error('Invalid media packet');
  const minimum = MINIMUM[bytes[0]];
  if (!minimum || bytes.length < minimum) throw new Error('Invalid media packet');
  return bytes[0];
}
export function isInitialization(kind) { return kind === KIND.INIT || kind === KIND.CONFIG; }
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
const hex = v => v.toString(16).padStart(2, '0');
export function avcCodecString(avcC) {
  if (!avcC || avcC.length < 7 || avcC[0] !== 1) throw new Error('Invalid AVC configuration');
  return `avc1.${hex(avcC[1])}${hex(avcC[2])}${hex(avcC[3])}`;
}
function view(bytes) { const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes); return { b, dv: new DataView(b.buffer, b.byteOffset, b.byteLength) }; }
function microseconds(dv, at) {
  const high = dv.getUint32(at), low = dv.getUint32(at + 4);
  return high * 4294967296 + low; // exact below 2^53 µs (285 years)
}
// 3 config : u16 width, u16 height, u32 audio sample rate, u8 channels, avcC
export function parseConfig(bytes) {
  const { b, dv } = view(bytes);
  if (validatePacket(b) !== KIND.CONFIG) throw new Error('Not a configuration packet');
  const width = dv.getUint16(1), height = dv.getUint16(3), sampleRate = dv.getUint32(5), channels = b[9];
  const avcC = b.slice(10);
  if (width < 2 || height < 2 || sampleRate < 8000 || sampleRate > 192000 || channels < 1 || channels > 2) throw new Error('Invalid configuration');
  return { width, height, sampleRate, channels, avcC, codec: avcCodecString(avcC) };
}
// 4 video : u64 pts µs, u8 flags (bit0 key), AVCC access unit (4-byte NAL lengths)
export function parseVideo(bytes) {
  const { b, dv } = view(bytes);
  if (validatePacket(b) !== KIND.VIDEO) throw new Error('Not a picture packet');
  const data = b.slice(10);
  let at = 0;
  while (at + 4 <= data.length) { const size = new DataView(data.buffer, data.byteOffset + at, 4).getUint32(0); if (size === 0) throw new Error('Invalid access unit'); at += 4 + size; }
  if (at !== data.length) throw new Error('Invalid access unit');
  return { pts: microseconds(dv, 1), key: (b[9] & 1) === 1, data };
}
// 5 audio : u64 pts µs, interleaved s16le PCM
export function parseAudio(bytes, channels = 2) {
  const { b, dv } = view(bytes);
  if (validatePacket(b) !== KIND.AUDIO) throw new Error('Not an audio packet');
  const payload = b.length - 9, frameBytes = 2 * channels;
  if (payload % frameBytes !== 0) throw new Error('Misaligned PCM');
  const frames = payload / frameBytes, samples = new Int16Array(frames * channels);
  for (let i = 0; i < samples.length; i++) samples[i] = dv.getInt16(9 + i * 2, true);
  return { pts: microseconds(dv, 1), frames, samples };
}
