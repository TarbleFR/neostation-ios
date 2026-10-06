// Sample-accurate PCM ring for the v2 frame protocol. Pure logic shared by
// the AudioWorklet and the Node tests: no Web Audio API inside.
//
// Writes carry the sender's 48 kHz frame-counter timestamps. A gap between two
// packets is filled with silence of the exact missing length, an overlap is
// trimmed, so the ring always holds a continuous timeline and never seeks.
// Reads consume frames at a ratio close to 1: slightly faster when the cushion
// grows beyond its target, slightly slower when it shrinks, by linear
// interpolation. The ear cannot hear a 1.5 % rate change; it hears every seek.
export class AudioRing {
  constructor({ sampleRate = 48000, channels = 2, capacitySeconds = 2, targetSeconds = 0.08, windowSeconds = 0.03, rateStep = 0.015, baseRatio = 1 } = {}) {
    if (!(channels === 1 || channels === 2)) throw new RangeError('channels');
    this.sampleRate = sampleRate; this.channels = channels;
    this.capacity = Math.max(1024, Math.floor(sampleRate * capacitySeconds));
    this.target = Math.floor(sampleRate * targetSeconds);
    this.window = Math.floor(sampleRate * windowSeconds);
    this.rateStep = rateStep;
    this.base = baseRatio > 0 && Number.isFinite(baseRatio) ? baseRatio : 1; // stream rate / device rate
    this.left = new Float32Array(this.capacity); this.right = new Float32Array(this.capacity);
    this.reset();
  }
  reset() {
    this.readIndex = 0; this.writeIndex = 0; this.available = 0; this.fraction = 0;
    this.nextPts = null; this.headPts = null; this.ratio = 1;
    this.stats = { written: 0, played: 0, silence: 0, trimmed: 0, overruns: 0, underruns: 0, gaps: 0 };
  }
  get fill() { return this.available; }
  get fillSeconds() { return this.available / this.sampleRate; }
  // Presentation time (µs) of the frame under the read head; null before the first write.
  get clockPts() { return this.headPts === null ? null : this.headPts + Math.floor((this.fraction) * 1e6 / this.sampleRate); }
  frameMicroseconds(frames) { return frames * 1e6 / this.sampleRate; }
  write({ pts, samples, frames = samples.length / this.channels }) {
    if (!Number.isFinite(pts) || frames <= 0) return;
    let offset = 0;
    if (this.nextPts !== null) {
      const delta = pts - this.nextPts, tolerance = this.frameMicroseconds(2);
      if (delta > tolerance) {
        const missing = Math.min(this.capacity - this.available, Math.round(delta * this.sampleRate / 1e6));
        this.stats.gaps++; this.stats.silence += missing;
        for (let i = 0; i < missing; i++) this.push(0, 0);
      } else if (delta < -tolerance) {
        offset = Math.min(frames, Math.round(-delta * this.sampleRate / 1e6));
        this.stats.trimmed += offset;
      }
    } else { this.headPts = pts; }
    const scale = 1 / 32768;
    for (let f = offset; f < frames; f++) {
      const l = samples[f * this.channels] * scale, r = this.channels === 2 ? samples[f * this.channels + 1] * scale : l;
      this.push(l, r);
    }
    this.stats.written += frames - offset;
    this.nextPts = pts + this.frameMicroseconds(frames);
  }
  push(l, r) {
    if (this.available >= this.capacity) { this.readIndex = (this.readIndex + 1) % this.capacity; this.available--; this.stats.overruns++; this.advanceHead(1); }
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
    this.ratio = this.currentRatio();
    let produced = 0;
    for (let i = 0; i < count; i++) {
      if (this.available < 2) {
        if (this.available === 1 && this.fraction < 1) { outL[i] = this.left[this.readIndex]; outR[i] = this.right[this.readIndex]; this.consume(); produced++; continue; }
        outL[i] = 0; outR[i] = 0; this.stats.underruns++; continue;
      }
      const a = this.readIndex, b = (a + 1) % this.capacity, t = this.fraction;
      outL[i] = this.left[a] + (this.left[b] - this.left[a]) * t;
      outR[i] = this.right[a] + (this.right[b] - this.right[a]) * t;
      this.fraction += this.ratio;
      while (this.fraction >= 1 && this.available > 0) { this.fraction -= 1; this.consume(); }
      produced++;
    }
    this.stats.played += produced;
    return produced;
  }
  consume() { this.readIndex = (this.readIndex + 1) % this.capacity; this.available--; this.advanceHead(1); }
}
