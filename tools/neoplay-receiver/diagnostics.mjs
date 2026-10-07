import { KIND } from './protocol.mjs';

// Receipt metadata only: no payloads, PINs, addresses or tokens. The bounded
// history is exported on demand; no disk/network work runs on the audio thread.
// UTC correlates with NPLog.time; media PTS and monotonic time stay separate.
export class ReceiverDiagnostics {
  constructor({ now = () => performance.now(), wall = () => Date.now(), maxSamples = 1200 } = {}) {
    this.now = now; this.wall = wall; this.maxSamples = Math.max(1, Math.floor(maxSamples));
    this.startedAt = wall(); this.startedMono = now(); this.sampledAt = this.startedMono;
    this.bytes = 0; this.packets = 0; this.sampledBytes = 0; this.sampledPackets = 0;
    this.counts = { configurations: 0, video: 0, pcm: 0, initializations: 0, segments: 0 };
    this.lastMediaPtsUs = { video: null, pcm: null };
    this.lastPCMAt = null; this.pcmArrivalGapMaxMs = 0; this.queueWaitMaxMs = 0;
    this.samples = []; this.samplesDiscarded = 0;
  }
  received(packet, at = this.now()) {
    this.bytes += packet.byteLength; this.packets++;
    const key = { [KIND.CONFIG]: 'configurations', [KIND.VIDEO]: 'video', [KIND.AUDIO]: 'pcm', [KIND.INIT]: 'initializations', [KIND.SEGMENT]: 'segments' }[packet[0]];
    if (key) this.counts[key]++;
    if ((key === 'video' || key === 'pcm') && packet.byteLength >= 9) {
      const view = new DataView(packet.buffer, packet.byteOffset, packet.byteLength);
      this.lastMediaPtsUs[key] = view.getUint32(1) * 4294967296 + view.getUint32(5);
    }
    if (key === 'pcm') {
      if (this.lastPCMAt !== null) this.pcmArrivalGapMaxMs = Math.max(this.pcmArrivalGapMaxMs, at - this.lastPCMAt);
      this.lastPCMAt = at;
    }
  }
  processed(receivedAt, at = this.now()) { this.queueWaitMaxMs = Math.max(this.queueWaitMaxMs, at - receivedAt); }
  sample(mode, playback) {
    const at = this.now(), elapsed = Math.max(0, at - this.sampledAt);
    const row = {
      time: new Date(this.wall()).toISOString(), elapsedMs: at - this.startedMono, intervalMs: elapsed, mode,
      receive: {
        bytes: this.bytes, packets: this.packets, ...this.counts,
        megabitsPerSecond: elapsed > 0 ? (this.bytes - this.sampledBytes) * 8 / elapsed / 1000 : 0,
        packetsPerSecond: elapsed > 0 ? (this.packets - this.sampledPackets) * 1000 / elapsed : 0,
        lastMediaPtsUs: { ...this.lastMediaPtsUs }, pcmArrivalGapMaxMs: this.pcmArrivalGapMaxMs, queueWaitMaxMs: this.queueWaitMaxMs,
      },
      playback: structuredClone(playback),
    };
    this.sampledAt = at; this.sampledBytes = this.bytes; this.sampledPackets = this.packets;
    this.pcmArrivalGapMaxMs = 0; this.queueWaitMaxMs = 0;
    this.samples.push(row);
    if (this.samples.length > this.maxSamples) { this.samples.shift(); this.samplesDiscarded++; }
    return row;
  }
  export() {
    return {
      schema: 'neoplay-receiver-diagnostics-v1', startedAt: new Date(this.startedAt).toISOString(), samplesDiscarded: this.samplesDiscarded,
      units: { time: 'UTC; cross-device comparison requires synchronized clocks', elapsedMs: 'receiver monotonic milliseconds', lastMediaPtsUs: 'sender media microseconds, not wall clock', pcmArrivalGapMaxMs: 'maximum browser PCM receipt interval in this sample window', queueWaitMaxMs: 'maximum receiver promise-queue delay in this sample window', droppedLate: 'video frames', underruns: 'output PCM frames, not packets or underrun events', ratio: 'resampling ratio, not network throughput', skips: 'audio ring skip events' },
      samples: structuredClone(this.samples),
    };
  }
}
