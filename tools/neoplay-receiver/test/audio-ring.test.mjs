import test from 'node:test';
import assert from 'node:assert/strict';
import { AudioRing } from '../audio-ring.mjs';
const RATE = 48000;
const pcm = (frames, value) => { const s = new Int16Array(frames * 2); s.fill(value); return s; };
const micro = frames => frames * 1e6 / RATE;
function drain(ring, frames) { const l = new Float32Array(frames), r = new Float32Array(frames); const produced = ring.read(l, r); return { l, r, produced }; }
test('contiguous packets play back exactly once, in order, without seeking', () => {
  const ring = new AudioRing({ sampleRate: RATE });
  for (let i = 0; i < 4; i++) ring.write({ pts: micro(i * 480), samples: pcm(480, (i + 1) * 1000) });
  assert.equal(ring.fill, 1920);
  const { l, produced } = drain(ring, 1920);
  assert.equal(produced, 1920); assert.equal(ring.stats.underruns, 0); assert.equal(ring.stats.gaps, 0); assert.equal(ring.stats.trimmed, 0);
  assert.ok(Math.abs(l[0] - 1000 / 32768) < 1e-6); assert.ok(Math.abs(l[1919] - 4000 / 32768) < 1e-6);
  assert.equal(ring.stats.played, 1920);
});
test('a timestamp gap is filled with silence of the exact missing length', () => {
  const ring = new AudioRing({ sampleRate: RATE });
  ring.write({ pts: 0, samples: pcm(480, 5000) });
  ring.write({ pts: micro(480 + 240), samples: pcm(480, 5000) }); // 5 ms missing
  assert.equal(ring.stats.gaps, 1); assert.equal(ring.stats.silence, 240); assert.equal(ring.fill, 1200);
  const { l } = drain(ring, 1200);
  assert.ok(Math.abs(l[479] - 5000 / 32768) < 1e-6);
  assert.equal(l[600], 0); // inside the filled gap
  assert.ok(Math.abs(l[1100] - 5000 / 32768) < 1e-6);
});
test('an overlapping packet is trimmed instead of duplicating samples', () => {
  const ring = new AudioRing({ sampleRate: RATE });
  ring.write({ pts: 0, samples: pcm(480, 1) });
  ring.write({ pts: micro(400), samples: pcm(480, 2) }); // 80 frames already played
  assert.equal(ring.stats.trimmed, 80); assert.equal(ring.fill, 880);
});
test('the cushion is held by a small rate change, never by dropping or jumping', () => {
  const ring = new AudioRing({ sampleRate: RATE, targetSeconds: 0.08, windowSeconds: 0.03, rateStep: 0.015 });
  for (let i = 0; i < 20; i++) ring.write({ pts: micro(i * 480), samples: pcm(480, 100) }); // 200 ms queued
  drain(ring, 128); assert.equal(ring.ratio, 1.015);
  while (ring.fill > RATE * 0.11) drain(ring, 128);
  drain(ring, 128); assert.equal(ring.ratio, 1);
  while (ring.fill > RATE * 0.05) drain(ring, 128);
  drain(ring, 128); assert.equal(ring.ratio, 0.985);
  assert.equal(ring.stats.overruns, 0); assert.equal(ring.stats.underruns, 0);
});
test('underrun outputs silence and the clock waits for data', () => {
  const ring = new AudioRing({ sampleRate: RATE });
  assert.equal(ring.clockPts, null);
  ring.write({ pts: 2_000_000, samples: pcm(100, 300) });
  const { l, produced } = drain(ring, 256);
  assert.ok(produced >= 100 && produced <= 103, String(produced)); // slow-rate stretch of the short cushion
  assert.equal(ring.stats.underruns, 256 - produced); assert.equal(l[200], 0);
  assert.ok(ring.clockPts >= 2_000_000 + micro(99) && ring.clockPts <= 2_000_000 + micro(101));
});
test('the clock follows consumed sender frames', () => {
  const ring = new AudioRing({ sampleRate: RATE, targetSeconds: 0.01, windowSeconds: 0.5 });
  ring.write({ pts: 1_000_000, samples: pcm(4800, 10) });
  drain(ring, 2400);
  assert.ok(Math.abs(ring.clockPts - (1_000_000 + micro(2400))) < micro(2));
});
test('a stream rate different from the device rate is folded into the base ratio', () => {
  const ring = new AudioRing({ sampleRate: 48000, baseRatio: 44100 / 48000, targetSeconds: 0.01, windowSeconds: 1 });
  ring.write({ pts: 0, samples: pcm(4410, 10) });
  const { produced } = drain(ring, 4800);
  assert.equal(produced, 4800); assert.ok(ring.fill <= 2);
});
test('overrun keeps the newest audio and counts what it dropped', () => {
  const ring = new AudioRing({ sampleRate: RATE, capacitySeconds: 0.1 });
  for (let i = 0; i < 20; i++) ring.write({ pts: micro(i * 480), samples: pcm(480, 7) });
  assert.ok(ring.stats.overruns > 0); assert.ok(ring.fill <= ring.capacity);
});
