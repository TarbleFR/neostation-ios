import test from 'node:test';
import assert from 'node:assert/strict';
import { audioTime, isLive, choose, overflow, engineFor, LEAD_US, SPAN_US, MAX_QUEUE } from '../presenter.mjs';
import { KIND } from '../protocol.mjs';
// Presentation of a picture train against an audio clock posted every 21.33 ms
// (8 quanta of 128 frames at 48 kHz), one presentation per display refresh.
// Pictures arrive on time and the sound carries a cushion, so the clock runs
// `cushionMs` behind the pictures.
function simulate({ fps = 60, seconds = 4, clockStepMs = 1024 / 48, rafMs = 1000 / 60, cushionMs = 80, interpolate = true, stallFrom = Infinity, stallMs = 0 }) {
  const periodUs = 1e6 / fps, queue = [], clock = { pts: null, updatedAt: 0, running: false };
  let nextFrame = 0, frameIndex = 0, nextPost = 0, nextRaf = 0, presented = 0, late = 0, overflowed = 0, freeRun = 0, skipAhead = 0;
  for (let t = 0; t <= seconds * 1000; t += 0.25) {
    while (nextFrame <= t) { queue.push(frameIndex * periodUs); frameIndex++; nextFrame += 1000 / fps; const drop = overflow(queue); queue.splice(0, drop); overflowed += drop; }
    const stalled = t >= stallFrom && t < stallFrom + stallMs;
    if (t >= stallFrom + stallMs && skipAhead === 0 && stallMs > 0) skipAhead = stallMs; // the ring skipped the stale burst: the clock jumps
    if (t >= nextPost) { clock.running = !stalled; if (!stalled) { clock.pts = Math.max(0, (t - cushionMs) * 1000); clock.updatedAt = t; } nextPost += clockStepMs; } // a starving ring posts the same pts, not running
    if (t >= nextRaf) {
      nextRaf += rafMs;
      if (!queue.length) continue;
      let index, lateHere;
      if (isLive(clock, t)) {
        const pts = interpolate ? audioTime(clock, t) : clock.pts;
        ({ index, late: lateHere } = choose(queue, pts));
        if (index < 0) continue;
      } else { index = lateHere = queue.length - 1; freeRun++; }
      late += lateHere; queue.splice(0, index + 1); presented++;
    }
  }
  return { presented, late, overflowed, freeRun, queued: queue.length, frames: frameIndex };
}
test('a 60 fps train on a 21 ms audio clock is presented whole: the clock is extrapolated and the oldest due picture is shown', () => {
  const run = simulate({ fps: 60 });
  assert.equal(run.late, 0); assert.equal(run.overflowed, 0);
  assert.ok(run.presented >= run.frames - 6, `${run.presented} of ${run.frames}`);
  const stepping = simulate({ fps: 60, interpolate: false }); // even a stepping clock no longer thins the train
  assert.equal(stepping.late, 0); assert.ok(stepping.presented >= stepping.frames - 6);
});
test('30 fps and 120 fps trains are presented at their own cadence without late drops', () => {
  const thirty = simulate({ fps: 30 }); assert.equal(thirty.late, 0); assert.ok(thirty.presented >= thirty.frames - 4);
  const fast = simulate({ fps: 120 }); // a 60 Hz display shows every other picture: the skipped ones are late by construction
  assert.ok(fast.presented >= 60 * 4 - 6); assert.ok(fast.late <= fast.frames / 2 + 6);
});
test('a stalled audio clock frees the pictures after 150 ms, and the skip that ends the stall drops only stale pictures', () => {
  const run = simulate({ fps: 60, stallFrom: 1000, stallMs: 400 });
  assert.ok(run.freeRun > 10, String(run.freeRun)); // 250 ms of the 400 ms stall shown on the pictures' own pace
  assert.ok(run.late <= 30, String(run.late)); // the cushion's worth of pictures that the jump left behind
  assert.ok(run.presented >= run.frames - 40, `${run.presented} of ${run.frames}`);
});
test('choose: the oldest due picture wins, pictures more than 25 ms behind a newer due one are late, nothing early is shown', () => {
  assert.deepEqual(choose([100_000, 116_667, 133_333], 110_000), { index: 0, late: 0 });
  assert.deepEqual(choose([100_000, 116_667, 133_333], 130_000), { index: 1, late: 1 });
  assert.deepEqual(choose([100_000, 116_667], 100_000 - LEAD_US - 1), { index: -1, late: 0 });
  assert.deepEqual(choose([100_000], 500_000), { index: 0, late: 0 }); // the only picture is shown however late
});
test('the audio clock is extrapolated between posts and corrected by the output latency; it goes stale after 150 ms', () => {
  const clock = { pts: 1_000_000, updatedAt: 500, running: true };
  assert.equal(audioTime(clock, 510), 1_010_000); assert.equal(audioTime(clock, 510, 40_000), 970_000);
  assert.equal(audioTime({ ...clock, running: false }, 510), 1_000_000); // prerolling or starving: the clock stands still
  assert.equal(audioTime({ pts: null, updatedAt: 0 }, 10), null);
  assert.ok(isLive(clock, 649)); assert.ok(!isLive(clock, 650)); assert.ok(!isLive({ pts: null, updatedAt: 0 }, 10));
});
test('decoded pictures are bounded by time and by count, oldest out first', () => {
  const sixty = [], fast = []; for (let i = 0; i < 40; i++) { sixty.push(i * 16_667); fast.push(i * 8_333); }
  assert.equal(overflow(sixty), 10); // 500 ms at 60 fps: 30 pictures
  assert.equal(overflow(fast), 40 - MAX_QUEUE); // 325 ms at 120 fps: the count bound
  assert.equal(overflow([0, SPAN_US + 1]), 1); assert.equal(overflow([0, SPAN_US]), 0); assert.equal(overflow([0]), 0);
});
test('a later frames configuration reuses the running engine; only an initialization or a protocol change builds one', () => {
  assert.equal(engineFor(KIND.INIT, null), 'segments'); assert.equal(engineFor(KIND.INIT, 'frames'), 'segments'); assert.equal(engineFor(KIND.INIT, 'segments'), 'segments');
  assert.equal(engineFor(KIND.CONFIG, null), 'frames'); assert.equal(engineFor(KIND.CONFIG, 'segments'), 'frames');
  assert.equal(engineFor(KIND.CONFIG, 'frames'), null, 'a quality change keeps the audio node, ring and clock');
  for (const kind of [KIND.VIDEO, KIND.AUDIO, KIND.SEGMENT]) { assert.equal(engineFor(kind, 'frames'), null); assert.equal(engineFor(kind, null), null); }
});
