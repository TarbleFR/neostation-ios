import test from 'node:test';
import assert from 'node:assert/strict';
import { AudioRing } from '../audio-ring.mjs';
const RATE = 48000;
const pcm = (frames, value) => { const s = new Int16Array(frames * 2); s.fill(value); return s; };
const micro = frames => frames * 1e6 / RATE;
function drain(ring, frames) { const l = new Float32Array(frames), r = new Float32Array(frames); const produced = ring.read(l, r); return { l, r, produced }; }
// Feeds `packets` contiguous packets of `frames` frames starting at `pts` (µs). Returns the pts after the last one.
function feed(ring, pts, packets, frames, value = 10) { for (let i = 0; i < packets; i++) { ring.write({ pts: pts + micro(i * frames), samples: pcm(frames, value) }); } return pts + micro(packets * frames); }
test('contiguous packets play back exactly once, in order, without seeking', () => {
  const ring = new AudioRing({ sampleRate: RATE, targetSeconds: 0.01 });
  for (let i = 0; i < 4; i++) ring.write({ pts: micro(i * 480), samples: pcm(480, (i + 1) * 1000) });
  assert.equal(ring.fill, 1920);
  const { l, produced } = drain(ring, 1920);
  assert.equal(produced, 1920); assert.equal(ring.stats.underruns, 0); assert.equal(ring.stats.gaps, 0); assert.equal(ring.stats.trimmed, 0); assert.equal(ring.stats.skips, 0);
  assert.ok(Math.abs(l[0] - 1000 / 32768) < 1e-6); assert.ok(Math.abs(l[1919] - 4000 / 32768) < 1e-6);
  assert.equal(ring.stats.played, 1920);
});
test('a short timestamp gap is filled with silence of the exact missing length', () => {
  const ring = new AudioRing({ sampleRate: RATE, targetSeconds: 0.01 });
  ring.write({ pts: 0, samples: pcm(480, 5000) });
  ring.write({ pts: micro(480 + 240), samples: pcm(480, 5000) }); // 5 ms missing
  assert.equal(ring.stats.gaps, 1); assert.equal(ring.stats.silence, 240); assert.equal(ring.fill, 1200); assert.equal(ring.stats.jumps, 0);
  const { l } = drain(ring, 1200);
  assert.ok(Math.abs(l[479] - 5000 / 32768) < 1e-6);
  assert.equal(l[600], 0); // inside the filled gap
  assert.ok(Math.abs(l[1100] - 5000 / 32768) < 1e-6);
});
test('an overlapping packet is trimmed instead of duplicating samples; an entirely stale one is dropped without moving the timeline back', () => {
  const ring = new AudioRing({ sampleRate: RATE });
  ring.write({ pts: 0, samples: pcm(480, 1) });
  ring.write({ pts: micro(400), samples: pcm(480, 2) }); // 80 frames already queued
  assert.equal(ring.stats.trimmed, 80); assert.equal(ring.fill, 880);
  const next = ring.nextPts;
  ring.write({ pts: 0, samples: pcm(480, 3) }); // a late duplicate of the first packet
  assert.equal(ring.stats.dropped, 480); assert.equal(ring.fill, 880); assert.equal(ring.nextPts, next);
  ring.write({ pts: next, samples: pcm(480, 4) });
  assert.equal(ring.stats.gaps, 0); assert.equal(ring.fill, 1360); // still contiguous: no silence was invented
});
test('the ring prerolls in silence until the cushion reaches its target, then plays without an underrun', () => {
  const ring = new AudioRing({ sampleRate: RATE, targetSeconds: 0.08 });
  assert.equal(ring.clockPts, null);
  assert.equal(drain(ring, 128).produced, 0); assert.equal(ring.stats.underruns, 0); assert.equal(ring.stats.preroll, 0); // before any packet: silence, not even a preroll
  let pts = feed(ring, 2_000_000, 4, 480); // 40 ms: half the cushion
  assert.equal(drain(ring, 128).produced, 0); assert.equal(ring.stats.preroll, 128); assert.equal(ring.stats.underruns, 0);
  assert.equal(ring.clockPts, 2_000_000); // the clock waits with the sound
  pts = feed(ring, pts, 4, 480); // 80 ms: the target
  const { produced, l } = drain(ring, 128);
  assert.equal(produced, 128); assert.ok(Math.abs(l[0] - 10 / 32768) < 1e-6); assert.equal(ring.stats.underruns, 0);
});
test('the cushion is held by a small rate change, never by dropping or jumping', () => {
  const ring = new AudioRing({ sampleRate: RATE, targetSeconds: 0.08, windowSeconds: 0.03, rateStep: 0.015 });
  feed(ring, 0, 20, 480); // 200 ms queued: within the excess bound, so it drains at 1.5 %
  drain(ring, 128); assert.equal(ring.ratio, 1.015); assert.equal(ring.stats.skips, 0);
  while (ring.fill > RATE * 0.11) drain(ring, 128);
  drain(ring, 128); assert.equal(ring.ratio, 1);
  while (ring.fill > RATE * 0.05) drain(ring, 128);
  drain(ring, 128); assert.equal(ring.ratio, 0.985);
  assert.equal(ring.stats.overruns, 0); assert.equal(ring.stats.underruns, 0); assert.equal(ring.stats.skips, 0);
});
test('a burst after a link stall is not drained for twenty seconds: the stale excess is skipped once and the clock jumps with it', () => {
  const ring = new AudioRing({ sampleRate: RATE, targetSeconds: 0.08, excessSeconds: 0.15 });
  let pts = feed(ring, 0, 8, 480); // 80 ms, primed
  drain(ring, 3840); // played out
  drain(ring, 19200); // 400 ms stall: silence
  assert.equal(ring.stats.underruns, 19200); assert.equal(ring.primed, false);
  pts = feed(ring, pts, 48, 480); // the transport's 480 ms burst, contiguous with what was played
  assert.equal(ring.fill, 23040);
  const { produced } = drain(ring, 128);
  assert.equal(produced, 128); assert.equal(ring.stats.skips, 1);
  assert.ok(ring.fill <= ring.target && ring.fill > ring.target - 200, `${ring.fill} vs ${ring.target}`);
  assert.ok(Math.abs(ring.clockPts - (pts - micro(ring.fill))) < micro(4), `${ring.clockPts} vs ${pts - micro(ring.fill)}`); // the clock sits where the head now is
  assert.equal(ring.targetSeconds, 0.25); // a 400 ms deficit the sender did not explain: the cushion grows to its bound
});
test('a gap longer than the cushion bound is not padded: the clock jumps to the new sound when the head reaches it', () => {
  const ring = new AudioRing({ sampleRate: RATE, targetSeconds: 0.08, excessSeconds: 0.15 });
  feed(ring, 0, 8, 480); // 80 ms queued, not yet consumed
  const resumed = micro(3840) + 3_000_000; // the game paused for three seconds
  ring.write({ pts: resumed, samples: pcm(480, 20) });
  assert.equal(ring.stats.jumps, 1); assert.equal(ring.stats.silence, 0); assert.equal(ring.fill, 3840 + 480);
  drain(ring, 3840);
  assert.ok(Math.abs(ring.clockPts - resumed) < micro(2), `${ring.clockPts} vs ${resumed}`); // the head crossed the junction
  const { l } = drain(ring, 100);
  assert.ok(Math.abs(l[0] - 20 / 32768) < 1e-6); // the new sound, not silence
  assert.equal(ring.stats.underruns, 0);
  // While dry, the jump is immediate.
  const ring2 = new AudioRing({ sampleRate: RATE, targetSeconds: 0.01 });
  feed(ring2, 0, 1, 480); drain(ring2, 480);
  ring2.write({ pts: micro(480) + 2_000_000, samples: pcm(480, 7) });
  assert.equal(ring2.stats.jumps, 1); assert.equal(ring2.clockPts, micro(480) + 2_000_000);
});
test('an underrun that the sender\'s own gap explains does not grow the cushion target', () => {
  const ring = new AudioRing({ sampleRate: RATE, targetSeconds: 0.08 });
  let pts = feed(ring, 0, 8, 480);
  drain(ring, 3840); drain(ring, 48000); // the app went silent for a second: no packets, no deficit
  assert.ok(ring.stats.underruns > 0);
  ring.write({ pts: pts + 1_000_000, samples: pcm(480, 1) }); // it resumes a second later on its own timeline
  assert.equal(ring.targetSeconds, 0.08);
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
test('the cushion target grows by the measured deficit, within bounds, and decays after a quiet half minute', () => {
  const ring = new AudioRing({ sampleRate: RATE, targetSeconds: 0.08, maxTargetSeconds: 0.25 });
  assert.equal(ring.targetSeconds, 0.08);
  let pts = feed(ring, 0, 8, 480);
  drain(ring, 3840 + 960); // 20 ms of silence: a hiccup, under the 30 ms window, so no preroll
  assert.equal(ring.primed, true);
  pts = feed(ring, pts, 8, 480); // the link catches up, contiguous
  assert.ok(ring.targetSeconds > 0.099 && ring.targetSeconds < 0.101, String(ring.targetSeconds)); // 80 + 20 ms
  drain(ring, 3840); drain(ring, 48000); // a long stall saturates the target at its bound once the sound returns
  pts = feed(ring, pts, 30, 480);
  assert.equal(ring.targetSeconds, 0.25);
  const before = ring.target;
  for (let i = 0; i < 400; i++) { ring.write({ pts, samples: pcm(4800, 10) }); pts += micro(4800); drain(ring, 4800); } // 40 quiet seconds
  assert.ok(ring.target < before && ring.target >= ring.minimumTarget, `${ring.target} ${before}`);
});
