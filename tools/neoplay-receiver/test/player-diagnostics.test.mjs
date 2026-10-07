import test from 'node:test';
import assert from 'node:assert/strict';
import { configPacket, videoPacket, audioPacket } from './packets.mjs';

// Exercise the production page event wiring without claiming browser decode or
// physical playback: the decoder/audio/DOM edges are explicitly fake here.
test('page diagnostics survive reconfiguration and stop, then reset on a new stream', async t => {
  const globals = {};
  const replace = (key, value) => { globals[key] = Object.getOwnPropertyDescriptor(globalThis, key); Object.defineProperty(globalThis, key, { configurable: true, writable: true, value }); };
  t.after(() => { for (const [key, descriptor] of Object.entries(globals)) { if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key]; } });
  const intervals = new Map(), animations = new Map(); let nextId = 0;
  replace('setInterval', fn => { const id = ++nextId; intervals.set(id, fn); return id; });
  replace('clearInterval', id => intervals.delete(id));
  replace('requestAnimationFrame', fn => { const id = ++nextId; animations.set(id, fn); return id; });
  replace('cancelAnimationFrame', id => animations.delete(id));
  const elements = Object.fromEntries(['video', 'canvas', 'status', 'stage', 'ready', 'auth', 'pin', 'full', 'stop'].map(key => [key, { textContent: '', dataset: { token: 'test-only' } }]));
  Object.assign(elements.video, { play: async () => {}, pause() {}, load() {}, removeAttribute() {}, addEventListener() {}, removeEventListener() {} });
  Object.assign(elements.canvas, { getContext: () => ({ drawImage() {} }) });
  Object.assign(elements.stage, { getBoundingClientRect: () => ({ width: 640, height: 480 }) });
  replace('document', { querySelector: selector => elements[selector.slice(1)] });
  replace('window', { addEventListener() {} }); replace('location', { host: 'localhost' }); replace('devicePixelRatio', 1);
  replace('ResizeObserver', class { observe() {} });
  const sockets = [];
  replace('WebSocket', class { static OPEN = 1; constructor() { this.readyState = 1; this.sent = []; sockets.push(this); } send(value) { this.sent.push(JSON.parse(value)); } close() { this.readyState = 3; this.onclose?.(); } });
  replace('AudioContext', class { constructor() { this.state = 'running'; this.sampleRate = 48000; this.audioWorklet = { addModule: async () => {} }; this.destination = {}; } });
  replace('AudioWorkletNode', class { constructor() { this.port = { postMessage() {} }; } connect() {} disconnect() {} });
  replace('EncodedVideoChunk', class { constructor(value) { Object.assign(this, value); } });
  replace('VideoDecoder', class {
    static async isConfigSupported() { return { supported: true }; }
    constructor(callbacks) { this.callbacks = callbacks; this.decodeQueueSize = 0; }
    configure() { this.state = 'configured'; }
    close() { this.state = 'closed'; }
    decode(chunk) { this.callbacks.output({ timestamp: chunk.timestamp, displayWidth: 640, displayHeight: 480, close() {} }); }
  });
  await import('../player.mjs');
  elements.ready.onclick(); const socket = sockets[0]; socket.onopen();
  const send = packet => socket.onmessage({ data: packet.buffer });
  const settle = () => new Promise(resolve => setImmediate(resolve));
  const snapshot = () => { for (const fn of intervals.values()) fn(); return window.neoplayDebug.diagnostics().samples.at(-1); };
  send(configPacket()); send(videoPacket(0, true)); send(audioPacket(0, 480)); await settle();
  for (const [id, fn] of animations) { animations.delete(id); fn(); }
  const first = snapshot();
  assert.equal(first.receive.video, 1); assert.equal(first.playback.presented, 1); assert.equal(first.receive.pcm, 1);
  assert.equal(first.playback.audioOutputSampleRate, 48000);
  assert.match(elements.status.textContent, /Receiving · frames/); assert.match(elements.status.textContent, /video 1\/1 · PCM 1/);
  assert.match(elements.status.textContent, /rx .* Mbps/); assert.match(elements.status.textContent, /underruns 0 PCM frames/);
  assert.equal(first.receive.segments, 0);
  send(configPacket(320, 240)); send(audioPacket(10_000, 480)); await settle();
  const changed = snapshot();
  assert.equal(changed.receive.configurations, 2); assert.equal(changed.receive.pcm, 2); assert.equal(changed.playback.reconfigures, 1);
  socket.onmessage({ data: JSON.stringify({ type: 'ended' }) });
  assert.equal(window.neoplayDebug.mode, null); assert.equal(intervals.size, 0);
  assert.equal(window.neoplayDebug.diagnostics().samples.at(-1).receive.pcm, 2);
  // An ended stream cannot revive through a queued asynchronous receive.
  send(configPacket()); send(audioPacket(0, 480)); socket.onmessage({ data: JSON.stringify({ type: 'ended' }) }); await settle();
  assert.equal(window.neoplayDebug.mode, null); assert.equal(intervals.size, 0);
  send(configPacket()); send(audioPacket(0, 480)); await settle();
  const restarted = snapshot();
  assert.equal(restarted.receive.configurations, 1); assert.equal(restarted.receive.pcm, 1); assert.equal(restarted.receive.video, 0);
  socket.close(); assert.equal(intervals.size, 0);
});
