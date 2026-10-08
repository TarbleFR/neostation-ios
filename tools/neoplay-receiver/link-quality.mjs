// Receiver feedback uses the sender's existing, tested keyframe/tier control.
// PTS deltas distinguish a delayed link from a game that simply produces fewer
// pictures. An isolated Wi-Fi spike never reduces quality.
export class LinkQuality {
  constructor() {
    this.offsets = []; this.lastPTS = null; this.lastAt = null;
    this.delayMs = 0; this.badSince = null; this.lastRequest = -Infinity;
    this.requests = 0; this.state = 'linkAutomatic'; this.rate = 0;
    this.presented = 0; this.sampledAt = null;
  }
  picture(ptsUs, at) {
    if (!Number.isFinite(ptsUs) || !Number.isFinite(at)) return;
    if (this.lastPTS !== null && ptsUs < this.lastPTS) this.offsets = [];
    this.lastPTS = ptsUs; this.lastAt = at;
    const offset = at - ptsUs / 1000;
    this.offsets.push({ at, offset });
    this.offsets = this.offsets.filter(row => at - row.at <= 5000).slice(-360);
    this.delayMs = Math.max(0, offset - Math.min(...this.offsets.map(row => row.offset)));
  }
  sample({ at, queueWaitMs = 0, decodeQueue = 0, presented = 0, active = true, visible = true }) {
    if (this.sampledAt !== null && at > this.sampledAt) this.rate = Math.max(0, (presented - this.presented) * 1000 / (at - this.sampledAt));
    this.presented = presented; this.sampledAt = at;
    const fresh = this.lastAt !== null && at - this.lastAt < 700;
    const congested = active && visible && fresh && (this.delayMs > 160 || queueWaitMs > 180 || decodeQueue > 6);
    if (!congested) { this.badSince = null; this.state = 'linkAutomatic'; return false; }
    this.state = 'linkAdjusting';
    this.badSince ??= at;
    // Three requests at least 500 ms apart enter the sender's 3-in-2s congestion window.
    // Its existing 5s cooldown and 20s clean recovery remain authoritative.
    if (at - this.badSince < 1000 || at - this.lastRequest < 500) return false;
    this.lastRequest = at; this.requests++; return true;
  }
  snapshot() { return { state:this.state, delayMs:this.delayMs, requests:this.requests, fps:this.rate }; }
}

export function decodePreferences(config, senderNeverReorders) {
  // Keep the validated software path for all current iPhone captures. Only
  // native 4K+ streams explicitly guaranteed not to reorder try the GPU first.
  return senderNeverReorders && config.width * config.height >= 3840 * 2160
    ? ['prefer-hardware', 'prefer-software', 'no-preference']
    : ['prefer-software', 'no-preference'];
}
