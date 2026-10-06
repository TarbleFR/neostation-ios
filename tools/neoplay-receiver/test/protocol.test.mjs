import test from 'node:test';
import assert from 'node:assert/strict';
import { KIND, displayLimits, validatePacket, isInitialization, parseConfig, parseVideo, parseAudio, avcCodecString } from '../protocol.mjs';
import { avcC, configPacket, videoPacket, audioPacket } from './packets.mjs';
test('display limits: v2 receivers lift the 1080p ceiling, v1 keep it', () => {
  assert.deepEqual(displayLimits({ width: 2560, height: 1440 }), { width: 2560, height: 1440, maxWidth: 1920, maxHeight: 1080, fps: 60, frames: false });
  assert.deepEqual(displayLimits({ width: 3840, height: 2160, frames: true }), { width: 3840, height: 2160, maxWidth: 7680, maxHeight: 4320, fps: 60, frames: true });
  assert.equal(displayLimits({ width: Infinity, height: 40000 }).height, 4320);
});
test('packet validation accepts both protocols and rejects truncated packets', () => {
  assert.equal(validatePacket(configPacket()), KIND.CONFIG);
  assert.equal(validatePacket(videoPacket(0, true)), KIND.VIDEO);
  assert.equal(validatePacket(audioPacket(0, 1)), KIND.AUDIO);
  assert.equal(validatePacket(Buffer.from([1, 0, 0, 0, 8, 102, 116, 121, 112])), KIND.INIT);
  for (const bytes of [Buffer.alloc(2), Buffer.alloc(10), Uint8Array.from([3, 0, 2, 0, 2, 0, 0, 0, 1, 2]), Uint8Array.from([4, 0, 0, 0, 0, 0, 0, 0, 0, 1]), Uint8Array.from([5, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3]), Uint8Array.from([6, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9])]) assert.throws(() => validatePacket(bytes));
  assert.ok(isInitialization(KIND.INIT) && isInitialization(KIND.CONFIG) && !isInitialization(KIND.VIDEO));
});
test('configuration packet carries picture size, PCM layout and the exact AVC codec string', () => {
  const config = parseConfig(configPacket(2868, 1320, 48000, 2));
  assert.equal(config.width, 2868); assert.equal(config.height, 1320); assert.equal(config.sampleRate, 48000); assert.equal(config.channels, 2);
  assert.equal(config.codec, 'avc1.64002a'); assert.deepEqual(Array.from(config.avcC), avcC);
  assert.throws(() => parseConfig(configPacket(0, 480))); assert.throws(() => avcCodecString(Uint8Array.from([2, 0, 0, 0, 0, 0, 0])));
});
test('picture packets: 53-bit microsecond timestamps, key flag and NAL tiling', () => {
  const picture = parseVideo(videoPacket(4_500_000_123, true));
  assert.equal(picture.pts, 4_500_000_123); assert.equal(picture.key, true); assert.deepEqual(Array.from(picture.data), [0, 0, 0, 4, 0x65, 1, 2, 3]);
  assert.equal(parseVideo(videoPacket(7, false)).key, false);
  assert.throws(() => parseVideo(Uint8Array.from([4, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 9, 1])));
});
test('audio packets decode interleaved little-endian PCM frames', () => {
  const audio = parseAudio(audioPacket(1_000_000, 3, -1234));
  assert.equal(audio.pts, 1_000_000); assert.equal(audio.frames, 3); assert.deepEqual(Array.from(audio.samples), [-1234, -1234, -1234, -1234, -1234, -1234]);
  assert.throws(() => parseAudio(Uint8Array.from([5, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6])));
});
