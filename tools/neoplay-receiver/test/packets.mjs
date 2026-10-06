// v2 packet builders shared by the receiver tests (not a test file).
const u16 = v => [v >> 8 & 255, v & 255], u32 = v => [v >>> 24 & 255, v >>> 16 & 255, v >>> 8 & 255, v & 255];
const u64 = v => { const high = Math.floor(v / 4294967296), low = v % 4294967296; return [...u32(high), ...u32(low)]; };
export const avcC = [1, 0x64, 0x00, 0x2a, 0xff, 0xe1, 0, 4, 0x67, 0x64, 0, 42, 1, 0, 2, 0x68, 0xee];
export const configPacket = (width = 640, height = 480, rate = 48000, channels = 2) => Uint8Array.from([3, ...u16(width), ...u16(height), ...u32(rate), channels, ...avcC]);
export const videoPacket = (pts, key, nal = [0x65, 1, 2, 3]) => Uint8Array.from([4, ...u64(pts), key ? 1 : 0, ...u32(nal.length), ...nal]);
export const audioPacket = (pts, frames, value = 1000) => { const bytes = [5, ...u64(pts)]; for (let i = 0; i < frames * 2; i++) bytes.push(value & 255, value >> 8 & 255); return Uint8Array.from(bytes); };
