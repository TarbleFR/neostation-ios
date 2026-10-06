import { mp4Mime, MAX_BUFFERED, displayLimits, KIND, parseConfig, parseVideo, parseAudio } from './protocol.mjs';
const video = document.querySelector('#video'), canvas = document.querySelector('#canvas'), status = document.querySelector('#status');
const say = text => { status.textContent = text; };
// Two engines. `frames` (v2): WebCodecs pictures and PCM on one sample-accurate
// audio clock, never a seek. `segments` (v1): MediaSource fMP4, the validated
// fallback for browsers without WebCodecs.
const framesCapable = typeof VideoDecoder !== 'undefined' && typeof EncodedVideoChunk !== 'undefined' && typeof AudioWorkletNode !== 'undefined' && typeof AudioContext !== 'undefined';
const segmentsCapable = typeof MediaSource !== 'undefined' && MediaSource.isTypeSupported('video/mp4; codecs="avc1.42E02A, mp4a.40.2"');
let socket, engine = null, audioContext = null, workletReady = null;
const debug = { stats: () => engine?.stats() ?? null, get audioNode() { return engine?.audioNode ?? null; }, get mode() { return engine?.mode ?? null; } };
window.neoplayDebug = debug;
function closeMedia() { engine?.close(); engine = null; }
function report() {
  if (socket?.readyState !== WebSocket.OPEN) return;
  const bounds = document.querySelector('#stage').getBoundingClientRect();
  socket.send(JSON.stringify({ type: 'display', ...displayLimits({ width: bounds.width * devicePixelRatio, height: bounds.height * devicePixelRatio, frames: framesCapable }), supported: framesCapable || segmentsCapable }));
}
function acknowledge() { if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'playback', playing: true })); }
async function ensureAudio() {
  if (!audioContext) audioContext = new AudioContext({ sampleRate: 48000, latencyHint: 'interactive' });
  if (!workletReady) workletReady = audioContext.audioWorklet.addModule('/audio-worklet.mjs');
  await workletReady;
  if (audioContext.state !== 'running') await audioContext.resume().catch(() => {});
  return audioContext;
}
// ---- v2: frames engine ------------------------------------------------------
function createFramesEngine() {
  let decoder = null, config = null, node = null, waitKey = true, acknowledged = false, raf = 0, closed = false;
  const queue = []; // decoded VideoFrames waiting for presentation, oldest first
  const clock = { pts: null, updatedAt: 0, lastPts: null, fillSeconds: 0, ratio: 1, stats: null };
  const counters = { pictures: 0, decoded: 0, presented: 0, droppedLate: 0, droppedQueue: 0, pcmPackets: 0, decodeErrors: 0 };
  const context = canvas.getContext('2d', { alpha: false, desynchronized: true });
  video.hidden = true; canvas.hidden = false;
  function present() {
    raf = 0; if (closed) return;
    if (!queue.length) return;
    // The audio clock leads presentation. If audio stalls (a menu without app
    // sound) for 150 ms the newest picture is shown on its own pace.
    const live = clock.pts !== null && performance.now() - clock.updatedAt < 150;
    let index = queue.length - 1;
    if (live) { index = -1; for (let i = 0; i < queue.length; i++) if (queue[i].timestamp <= clock.pts + 40000) index = i; if (index < 0) { raf = requestAnimationFrame(present); return; } }
    for (let i = 0; i < index; i++) { queue[i].close(); counters.droppedLate++; }
    const frame = queue[index]; queue.splice(0, index + 1);
    if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) { canvas.width = frame.displayWidth; canvas.height = frame.displayHeight; }
    context.drawImage(frame, 0, 0, canvas.width, canvas.height); frame.close(); counters.presented++;
    if (!acknowledged) { acknowledged = true; acknowledge(); }
    if (queue.length) raf = requestAnimationFrame(present);
  }
  function schedule() { if (!raf) raf = requestAnimationFrame(present); }
  async function configure(packet) {
    config = parseConfig(packet);
    const settings = { codec: config.codec, codedWidth: config.width, codedHeight: config.height, description: config.avcC, optimizeForLatency: true, hardwareAcceleration: 'prefer-hardware' };
    const support = await VideoDecoder.isConfigSupported(settings);
    if (!support.supported) { settings.hardwareAcceleration = 'no-preference'; if (!(await VideoDecoder.isConfigSupported(settings)).supported) throw new Error(`Codec unavailable: ${config.codec}`); }
    if (closed) return;
    decoder?.close();
    decoder = new VideoDecoder({ output: frame => { counters.decoded++; queue.push(frame); while (queue.length > 6) { queue.shift().close(); counters.droppedQueue++; } schedule(); }, error: error => { counters.decodeErrors++; say(`Decode failed: ${error.message}`); } });
    decoder.configure(settings); waitKey = true;
    canvas.width = config.width; canvas.height = config.height;
    const audio = await ensureAudio(); if (closed) return;
    if (!node) {
      node = new AudioWorkletNode(audio, 'neoplay-audio', { numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [2] });
      node.port.onmessage = ({ data }) => { if (data.type !== 'clock') return; if (data.pts !== null && data.pts !== clock.lastPts) { clock.updatedAt = performance.now(); clock.lastPts = data.pts; } clock.pts = data.pts; clock.fillSeconds = data.fillSeconds; clock.ratio = data.ratio; clock.stats = data.stats; schedule(); };
      node.connect(audio.destination);
    }
    node.port.postMessage({ type: 'configure', sampleRate: config.sampleRate, channels: config.channels });
  }
  function picture(packet) {
    if (!decoder || decoder.state !== 'configured') return;
    const { pts, key, data } = parseVideo(packet); counters.pictures++;
    if (waitKey && !key) return; waitKey = false;
    if (decoder.decodeQueueSize > 8) { if (!key) { waitKey = true; counters.droppedQueue++; return; } }
    decoder.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: pts, data }));
  }
  function sound(packet) {
    if (!node || !config) return;
    const { pts, samples } = parseAudio(packet, config.channels); counters.pcmPackets++;
    node.port.postMessage({ type: 'pcm', pts, samples }, [samples.buffer]);
  }
  const timer = setInterval(() => { if (config) say(`Receiving · frames · ${config.width}×${config.height} · audio cushion ${(clock.fillSeconds * 1000).toFixed(0)} ms · rate ${clock.ratio.toFixed(3)} · late ${counters.droppedLate} · underruns ${clock.stats?.underruns ?? 0}`); }, 500);
  return {
    mode: 'frames',
    get audioNode() { return node; },
    stats: () => ({ ...counters, queue: queue.length, clock: { ...clock }, config: config ? { width: config.width, height: config.height, sampleRate: config.sampleRate, channels: config.channels, codec: config.codec } : null }),
    async receive(packet) {
      if (packet[0] === KIND.CONFIG) await configure(packet);
      else if (packet[0] === KIND.VIDEO) picture(packet);
      else if (packet[0] === KIND.AUDIO) sound(packet);
    },
    close() {
      closed = true; clearInterval(timer); if (raf) cancelAnimationFrame(raf);
      for (const frame of queue) frame.close(); queue.length = 0;
      try { decoder?.close(); } catch {} decoder = null;
      node?.port.postMessage({ type: 'reset' }); node?.disconnect(); node = null;
      canvas.hidden = true; video.hidden = false;
    },
  };
}
// ---- v1: MediaSource segments engine ----------------------------------------
function createSegmentsEngine() {
  let mediaSource, buffer, objectURL, pending = [], pendingBytes = 0, generation = 0, started = false, closed = false;
  video.hidden = false; canvas.hidden = true;
  function release() {
    generation++; pending = []; pendingBytes = 0; started = false; buffer = null;
    video.pause(); video.removeAttribute('src'); video.load();
    if (objectURL) URL.revokeObjectURL(objectURL);
    objectURL = null; mediaSource = null;
  }
  function pump() {
    if (!buffer || buffer.updating || mediaSource.readyState !== 'open') return;
    try {
      if (buffer.buffered.length && video.currentTime > 5 && buffer.buffered.start(0) < video.currentTime - 4) { buffer.remove(0, video.currentTime - 3); return; }
      const data = pending.shift(); if (data) { pendingBytes -= data.byteLength; buffer.appendBuffer(data); }
    } catch (error) { say(`Playback failed: ${error.message}`); socket?.close(); release(); }
  }
  function enqueue(data) {
    if (pendingBytes + data.byteLength > MAX_BUFFERED || pending.length >= 32) { say('Receiver too slow. Reconnect at a lower resolution.'); socket?.close(); release(); return; }
    pending.push(data); pendingBytes += data.byteLength; pump();
  }
  function initialize(data) {
    release(); const epoch = generation; const mime = mp4Mime(data);
    if (!MediaSource.isTypeSupported(mime)) throw new Error(`Codec unavailable: ${mime}`);
    mediaSource = new MediaSource(); objectURL = URL.createObjectURL(mediaSource); video.src = objectURL;
    mediaSource.addEventListener('sourceopen', () => {
      if (epoch !== generation) return;
      buffer = mediaSource.addSourceBuffer(mime); buffer.mode = 'segments';
      buffer.addEventListener('updateend', () => { pump(); synchronize(); });
      buffer.addEventListener('error', () => { say('Media decoding failed.'); socket?.close(); });
      pump();
    }, { once: true }); enqueue(data);
  }
  function synchronize() {
    if (closed || !buffer?.buffered.length) return;
    const edge = buffer.buffered.end(buffer.buffered.length - 1), lag = edge - video.currentTime;
    if (!started && edge > 0.35) {
      started = true; video.currentTime = Math.max(buffer.buffered.start(0), edge - 0.3);
      video.play().catch(() => say('Click Ready again to allow audio playback.'));
    } else if (started && lag > 1.25) video.currentTime = Math.max(buffer.buffered.start(0), edge - 0.3);
    video.playbackRate = lag > 0.7 && lag <= 1.25 ? 1.03 : 1;
    if (started) say(`Receiving · segments · buffer ${Math.max(0, lag).toFixed(2)} s · ${video.videoWidth}×${video.videoHeight} · aspect preserved`);
  }
  const onTime = () => synchronize();
  const onPlaying = () => { if (video.readyState >= 2) acknowledge(); };
  video.addEventListener('timeupdate', onTime); video.addEventListener('playing', onPlaying);
  return {
    mode: 'segments', audioNode: null,
    stats: () => ({ time: video.currentTime, width: video.videoWidth, height: video.videoHeight, frames: video.getVideoPlaybackQuality?.().totalVideoFrames ?? 0 }),
    async receive(packet) {
      if (packet[0] === KIND.INIT) initialize(packet.slice(1).buffer);
      else if (packet[0] === KIND.SEGMENT && mediaSource) enqueue(packet.slice(1).buffer);
    },
    close() { closed = true; video.removeEventListener('timeupdate', onTime); video.removeEventListener('playing', onPlaying); release(); },
  };
}
document.querySelector('#ready').onclick = () => {
  if (framesCapable) ensureAudio().catch(() => {}); // user gesture: unlock audio output once
  if (socket?.readyState === WebSocket.OPEN) { video.play().catch(() => {}); report(); socket.send(JSON.stringify({ type: 'new_pin' })); return; }
  const auth = document.querySelector('#auth').dataset.token;
  socket = new WebSocket(`ws://${location.host}/v1/view?token=${auth}`); socket.binaryType = 'arraybuffer';
  socket.onopen = report;
  let chain = Promise.resolve();
  socket.onmessage = event => {
    try {
      if (typeof event.data === 'string') {
        const message = JSON.parse(event.data);
        if (message.type === 'state') { document.querySelector('#pin').textContent = message.connected ? '' : message.pin; say(message.connected ? 'Receiving…' : 'Select this PC in NeoPlay. PIN valid for five minutes.'); }
        if (message.type === 'ended') closeMedia(); return;
      }
      const packet = new Uint8Array(event.data);
      if (packet[0] === KIND.INIT || packet[0] === KIND.CONFIG) { closeMedia(); engine = packet[0] === KIND.CONFIG ? createFramesEngine() : createSegmentsEngine(); }
      if (!engine) return;
      const current = engine;
      chain = chain.then(() => current.receive(packet)).catch(error => { say(error.message); socket?.close(); closeMedia(); });
    } catch (error) { say(error.message); socket.close(); closeMedia(); }
  };
  socket.onclose = () => { closeMedia(); say('Receiver disconnected. Click Ready to restart.'); };
  socket.onerror = () => say('Cannot reach local NeoPlay Receiver.');
};
document.querySelector('#full').onclick = () => document.querySelector('#stage').requestFullscreen().catch(e => say(e.message));
document.querySelector('#stop').onclick = () => { if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'stop' })); };
new ResizeObserver(report).observe(document.querySelector('#stage'));
window.addEventListener('beforeunload', () => socket?.close());
