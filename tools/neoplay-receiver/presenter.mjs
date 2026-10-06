// Pure presentation logic of the frames engine, shared with the Node tests.
// Picture timestamps and audio times are microseconds on the sender's clock;
// `now` values are milliseconds from performance.now().
export const STALL_MS = 150;     // the audio clock has not moved for this long: pictures run on their own pace
export const LEAD_US = 10_000;   // a picture may be shown this early
export const LATE_US = 25_000;   // a due picture this far behind a newer due one is skipped
export const SPAN_US = 500_000;  // pictures waiting longer than this are not worth keeping
export const MAX_QUEUE = 36;     // decoded pictures held (500 ms at 60 fps)
// The worklet posts its clock every 21 ms while the sound keeps playing in
// between, so the clock is extrapolated at real time: the playback ratio is
// within 1.5 % of 1, an error under 0.3 ms per post. Without this the clock
// would step 21 ms at a time and a 60 fps train would lose every fifth
// picture. `latencyUs` is the output latency: what the worklet renders now is
// heard that much later, and the picture waits for the sound to be heard.
// While the ring prerolls or starves (`running` false) the clock stands still.
export function audioTime(clock, now, latencyUs = 0) {
  if (clock.pts === null) return null;
  return clock.pts + (clock.running === false ? 0 : (now - clock.updatedAt) * 1000) - latencyUs;
}
export function isLive(clock, now, stallMs = STALL_MS) { return clock.pts !== null && now - clock.updatedAt < stallMs; }
// Chooses the picture to present from timestamps sorted oldest first: the
// oldest due picture, skipping due pictures more than `lateUs` behind a newer
// due one. Returns {index, late}: index -1 when nothing is due yet, `late` the
// number of pictures to discard before index.
export function choose(timestamps, pts, { leadUs = LEAD_US, lateUs = LATE_US } = {}) {
  let last = -1;
  for (let i = 0; i < timestamps.length; i++) { if (timestamps[i] <= pts + leadUs) last = i; else break; }
  if (last < 0) return { index: -1, late: 0 };
  let first = 0;
  while (first < last && timestamps[first] < pts - lateUs) first++;
  return { index: first, late: first };
}
// Decoded pictures are bounded by time and count, oldest out first.
export function overflow(timestamps, { spanUs = SPAN_US, maxQueue = MAX_QUEUE } = {}) {
  let drop = 0;
  while (timestamps.length - drop > 1 && (timestamps.length - drop > maxQueue || timestamps[timestamps.length - 1] - timestamps[drop] > spanUs)) drop++;
  return drop;
}
