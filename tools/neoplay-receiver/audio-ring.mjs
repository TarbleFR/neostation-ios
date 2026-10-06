// Sample-accurate PCM ring for the v2 frame protocol. Pure logic shared by
// the AudioWorklet and the Node tests: no Web Audio API inside.
//
// Writes carry the sender's 48 kHz frame-counter timestamps. A short gap
// between two packets is filled with silence of the exact missing length, an
// overlap is trimmed, so the ring holds a continuous timeline. Reads consume
// frames at a ratio close to 1: slightly faster when the cushion grows beyond
// its target, slightly slower when it shrinks, by linear interpolation. The ear
// cannot hear a 1.5 % rate change; it hears every seek, so the ring moves its
// read head only where the listener already hears silence:
// - it prerolls (silence) until the cushion reaches its target, at the start
//   and after a stall, instead of resuming dry and crackling on every jitter;
// - the burst that follows a stall would leave the cushion far beyond its
//   target: the stale excess is skipped once (stats.skips), not drained for
//   twenty seconds at 1.5 %;
// - a gap longer than the cushion bound is not padded with silence: the clock
//   jumps to the new sound when the read head reaches it (stats.jumps), so a
//   paused game never leaves the clock seconds behind the sound.
// The cushion target adapts within bounds: an underrun that the sender's own
// timeline does not explain raises it by the deficit (up to 250 ms); thirty
// quiet seconds lower it by 10 ms.
export class AudioRing {
  constructor({ sampleRate = 48000, channels = 2, capacitySeconds = 2, targetSeconds = 0.08, maxTargetSeconds = 0.25, windowSeconds = 0.03, excessSeconds = 0.15, rateStep = 0.015, baseRatio = 1 } = {}) {
    if (!(channels === 1 || channels === 2)) throw new RangeError('channels');
    this.sampleRate = sampleRate; this.channels = channels;
    this.capacity = Math.max(1024, Math.floor(sampleRate * capacitySeconds));
    this.minimumTarget = Math.floor(sampleRate * targetSeconds);
    this.maximumTarget = Math.max(this.minimumTarget, Math.floor(sampleRate * maxTargetSeconds));
    this.target = this.minimumTarget;
    this.window = Math.floor(sampleRate * windowSeconds);
    this.excess = Math.floor(sampleRate * excessSeconds);
    this.rateStep = rateStep;
    this.base = baseRatio > 0 && Number.isFinite(baseRatio) ? baseRatio : 1; // stream rate / device rate
    this.left = new Float32Array(this.capacity); this.right = new Float32Array(this.capacity);
    this.reset();
  }
  reset() {
    this.readIndex = 0; this.writeIndex = 0; this.available = 0; this.fraction = 0;
    this.nextPts = null; this.headPts = null; this.ratio = 1; this.primed = false; this.junctions = [];
    this.target = this.minimumTarget; this.burst = 0; this.quietFrames = 0;
    this.stats = { written: 0, played: 0, silence: 0, trimmed: 0, dropped: 0, overruns: 0, underruns: 0, preroll: 0, gaps: 0, jumps: 0, skipped: 0, skips: 0 };
  }
  get fill() { return this.available; }
  get fillSeconds() { return this.available / this.sampleRate; }
  get targetSeconds() { return this.target / this.sampleRate; }
  get bound() { return this.target + this.excess; } // the cushion is never allowed to stay above this
  // Presentation time (µs) of the frame under the read head; null before the first write.
  get clockPts() { return this.headPts === null ? null : this.headPts + Math.floor((this.fraction) * 1e6 / this.sampleRate); }
  frameMicroseconds(frames) { return frames * 1e6 / this.sampleRate; }
  write({ pts, samples, frames = samples.length / this.channels }) {
    if (!Number.isFinite(pts) || frames <= 0) return;
    let offset = 0, explained = 0;
    if (this.nextPts !== null) {
      const delta = pts - this.nextPts, tolerance = this.frameMicroseconds(2);
      if (delta > tolerance) {
        const gap = Math.round(delta * this.sampleRate / 1e6); this.stats.gaps++; explained = gap;
        if (this.available + gap <= this.bound) { this.stats.silence += gap; for (let i = 0; i < gap; i++) this.push(0, 0); }
        else { // too long to pad: the clock jumps to the new sound once the head gets there
          this.stats.jumps++;
          if (this.available === 0) { this.headPts = pts; this.fraction = 0; } else this.junctions.push({ index: this.writeIndex, pts });
        }
      } else if (delta < -tolerance) {
        offset = Math.round(-delta * this.sampleRate / 1e6);
        if (offset >= frames) { this.stats.dropped += frames; return; } // entirely stale: that time was already played
        this.stats.trimmed += offset;
      }
    } else { this.headPts = pts; }
    if (this.burst > 0) { // the stall ended: grow the target by the deficit the sender's own timeline does not explain
      const deficit = this.burst - explained;
      if (deficit > 0) this.target = Math.min(this.maximumTarget, this.target + deficit);
      this.burst = 0; this.quietFrames = 0;
    }
    const scale = 1 / 32768;
    for (let f = offset; f < frames; f++) {
      const l = samples[f * this.channels] * scale, r = this.channels === 2 ? samples[f * this.channels + 1] * scale : l;
      this.push(l, r);
    }
    this.stats.written += frames - offset;
    this.nextPts = pts + this.frameMicroseconds(frames);
  }
  push(l, r) {
    if (this.available >= this.capacity) { this.consume(); this.stats.overruns++; }
    this.left[this.writeIndex] = l; this.right[this.writeIndex] = r;
    this.writeIndex = (this.writeIndex + 1) % this.capacity; this.available++;
  }
  advanceHead(frames) { if (this.headPts !== null) this.headPts += this.frameMicroseconds(frames); }
  currentRatio() {
    if (this.available > this.target + this.window) return this.base * (1 + this.rateStep);
    if (this.available < this.target - this.window) return this.base * (1 - this.rateStep);
    return this.base;
  }
  // Fills `count` output frames into outL/outR. Returns the number of output frames backed by data.
  read(outL, outR, count = outL.length) {
    if (this.nextPts === null) { outL.fill(0, 0, count); outR.fill(0, 0, count); return 0; } // nothing received yet: silence, not an underrun
    if (!this.primed) {
      if (this.available >= this.target) this.primed = true;
      else { // preroll: silence until the cushion is there. After a stall it still counts as the stall's deficit.
        outL.fill(0, 0, count); outR.fill(0, 0, count);
        if (this.burst > 0) { this.burst += count; this.stats.underruns += count; } else this.stats.preroll += count;
        return 0;
      }
    }
    if (this.available > this.bound) { const skip = this.available - this.target; this.skip(skip); this.stats.skipped += skip; this.stats.skips++; }
    this.ratio = this.currentRatio();
    let produced = 0;
    for (let i = 0; i < count; i++) {
      if (this.available < 2) {
        if (this.available === 1 && this.fraction < 1) { outL[i] = this.left[this.readIndex]; outR[i] = this.right[this.readIndex]; this.consume(); produced++; continue; }
        outL[i] = 0; outR[i] = 0; this.stats.underruns++; this.burst++; continue;
      }
      const a = this.readIndex, b = (a + 1) % this.capacity, t = this.fraction;
      outL[i] = this.left[a] + (this.left[b] - this.left[a]) * t;
      outR[i] = this.right[a] + (this.right[b] - this.right[a]) * t;
      this.fraction += this.ratio;
      while (this.fraction >= 1 && this.available > 0) { this.fraction -= 1; this.consume(); }
      produced++;
    }
    if (this.burst >= this.window) this.primed = false; // a real stall, not a hiccup: preroll again before resuming
    this.stats.played += produced;
    this.decay(count, produced);
    return produced;
  }
  // Called once per complete read: a quiet half minute lowers the target by 10 ms.
  decay(count, produced) {
    if (produced !== count || this.burst > 0) return;
    this.quietFrames += count;
    if (this.quietFrames >= this.sampleRate * 30) { this.quietFrames = 0; this.target = Math.max(this.minimumTarget, this.target - Math.floor(this.sampleRate * 0.01)); }
  }
  skip(frames) { for (let i = 0; i < frames && this.available > 0; i++) this.consume(); this.fraction = 0; }
  consume() {
    this.readIndex = (this.readIndex + 1) % this.capacity; this.available--; this.advanceHead(1);
    if (this.junctions.length && this.junctions[0].index === this.readIndex) { this.headPts = this.junctions[0].pts; this.junctions.shift(); }
  }
}
