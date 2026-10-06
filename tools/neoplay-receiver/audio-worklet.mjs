import { AudioRing } from './audio-ring.mjs';
// Runs on the audio rendering thread: pulls from the ring at the device rate.
class NeoPlayAudioProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ring = new AudioRing({ sampleRate, channels: 2 });
    this.counter = 0;
    this.port.onmessage = ({ data }) => {
      if (data.type === 'pcm') this.ring.write(data);
      else if (data.type === 'configure') {
        const channels = data.channels === 1 ? 1 : 2, baseRatio = (data.sampleRate || sampleRate) / sampleRate;
        if (this.ring.channels !== channels || this.ring.base !== baseRatio) this.ring = new AudioRing({ sampleRate, channels, baseRatio }); // same layout: the timeline continues
      }
      else if (data.type === 'reset') this.ring.reset();
      else if (data.type === 'close') this.closed = true; // the page released the node: stop rendering and posting clocks
    };
  }
  process(inputs, outputs) {
    if (this.closed) return false;
    const output = outputs[0]; if (!output || !output[0]) return true;
    const left = output[0], right = output[1] || output[0];
    const produced = this.ring.read(left, right, left.length);
    if (++this.counter % 8 === 0) this.port.postMessage({ type: 'clock', pts: this.ring.clockPts, running: produced > 0, fillSeconds: this.ring.fillSeconds, targetSeconds: this.ring.targetSeconds, ratio: this.ring.ratio, stats: { ...this.ring.stats } });
    return true;
  }
}
registerProcessor('neoplay-audio', NeoPlayAudioProcessor);
