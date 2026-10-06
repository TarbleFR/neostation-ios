import { AudioRing } from './audio-ring.mjs';
// Runs on the audio rendering thread: pulls from the ring at the device rate.
class NeoPlayAudioProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ring = new AudioRing({ sampleRate, channels: 2 });
    this.counter = 0;
    this.port.onmessage = ({ data }) => {
      if (data.type === 'pcm') this.ring.write(data);
      else if (data.type === 'configure') this.ring = new AudioRing({ sampleRate, channels: data.channels === 1 ? 1 : 2, baseRatio: (data.sampleRate || sampleRate) / sampleRate });
      else if (data.type === 'reset') this.ring.reset();
    };
  }
  process(inputs, outputs) {
    const output = outputs[0]; if (!output || !output[0]) return true;
    const left = output[0], right = output[1] || output[0];
    this.ring.read(left, right, left.length);
    if (++this.counter % 8 === 0) this.port.postMessage({ type: 'clock', pts: this.ring.clockPts, fillSeconds: this.ring.fillSeconds, ratio: this.ring.ratio, stats: { ...this.ring.stats } });
    return true;
  }
}
registerProcessor('neoplay-audio', NeoPlayAudioProcessor);
