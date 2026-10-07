import test from 'node:test';
import assert from 'node:assert/strict';
import { ReceiverDiagnostics } from '../diagnostics.mjs';
import { configPacket, videoPacket, audioPacket } from './packets.mjs';

test('receipt throughput uses monotonic time, separates v2 packets from legacy segments and preserves sender PTS', () => {
  let mono = 0, utc = Date.UTC(2026, 9, 7);
  const log = new ReceiverDiagnostics({ now: () => mono, wall: () => utc });
  const packets = [configPacket(), videoPacket(1_000_000, true), audioPacket(1_000_000, 480), audioPacket(1_010_000, 480)];
  log.received(packets[0]); mono = 10; log.received(packets[1]); log.received(packets[2]);
  mono = 20; log.received(packets[3]); log.processed(10);
  mono = 500; utc += 500;
  const row = log.sample('frames', { clock: { ratio: 1.015, stats: { underruns: 480 } } });
  const bytes = packets.reduce((sum, packet) => sum + packet.byteLength, 0);
  assert.equal(row.time, '2026-10-07T00:00:00.500Z');
  assert.equal(row.receive.bytes, bytes); assert.equal(row.receive.megabitsPerSecond, bytes * 8 / 500 / 1000);
  assert.equal(row.receive.packetsPerSecond, 8); assert.equal(row.receive.configurations, 1);
  assert.equal(row.receive.video, 1); assert.equal(row.receive.pcm, 2); assert.equal(row.receive.segments, 0);
  assert.deepEqual(row.receive.lastMediaPtsUs, { video: 1_000_000, pcm: 1_010_000 });
  assert.equal(row.receive.pcmArrivalGapMaxMs, 10); assert.equal(row.receive.queueWaitMaxMs, 10);
  assert.equal(row.playback.clock.ratio, 1.015); assert.equal(row.playback.clock.stats.underruns, 480);
  // A wall-clock correction cannot turn network throughput negative or spike it.
  mono = 1000; utc -= 60_000;
  const idle = log.sample('frames', {});
  assert.equal(idle.receive.megabitsPerSecond, 0); assert.equal(idle.receive.packetsPerSecond, 0);
  assert.equal(idle.receive.pcmArrivalGapMaxMs, 0); assert.equal(idle.receive.queueWaitMaxMs, 0);
  assert.equal(idle.elapsedMs, 1000); assert.equal(idle.receive.pcm, 2);
});

test('history is bounded, snapshot copies cannot mutate live counters, and each session starts empty', () => {
  let mono = 0;
  const log = new ReceiverDiagnostics({ now: () => mono, wall: () => 0, maxSamples: 2 });
  const playback = { clock: { stats: { underruns: 48 } } };
  mono = 500; log.sample('frames', playback); playback.clock.stats.underruns = 96;
  mono = 1000; log.sample('frames', playback);
  const exported = log.export();
  assert.equal(exported.samples[0].playback.clock.stats.underruns, 48);
  exported.samples[0].playback.clock.stats.underruns = 999;
  assert.equal(log.export().samples[0].playback.clock.stats.underruns, 48);
  mono = 1500; log.sample('frames', playback);
  assert.equal(log.export().samples.length, 2); assert.equal(log.export().samplesDiscarded, 1);
  assert.equal(log.export().samples[0].elapsedMs, 1000);
  const relaunch = new ReceiverDiagnostics({ now: () => mono, wall: () => 0 });
  const fresh = relaunch.sample('frames', {});
  assert.equal(fresh.receive.packets, 0); assert.equal(fresh.elapsedMs, 0); assert.equal(fresh.receive.megabitsPerSecond, 0);
});

test('legacy segment counters are independent, and no encoded media is retained in diagnostics', () => {
  let mono = 0;
  const log = new ReceiverDiagnostics({ now: () => mono, wall: () => 0 });
  const init = Uint8Array.from([1, 0, 0, 0, 8, 102, 116, 121, 112]);
  const segment = Uint8Array.from([2, 0, 0, 0, 8, 109, 111, 111, 102]);
  log.received(init); log.received(segment); mono = 500;
  const row = log.sample('segments', { frames: 5 });
  assert.equal(row.receive.initializations, 1); assert.equal(row.receive.segments, 1);
  assert.equal(row.receive.video, 0); assert.equal(row.receive.pcm, 0);
  assert.equal(row.receive.packetsPerSecond, 4); assert.deepEqual(row.receive.lastMediaPtsUs, { video: null, pcm: null });
  assert.ok(!JSON.stringify(log.export()).includes('payload'));
  assert.match(log.export().units.underruns, /output PCM frames/);
});
