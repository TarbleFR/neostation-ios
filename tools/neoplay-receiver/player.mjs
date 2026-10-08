import { mp4Mime, MAX_BUFFERED, displayLimits, KIND, parseConfig, parseVideo, parseAudio } from './protocol.mjs';
import { audioTime, isLive, choose, overflow, engineFor } from './presenter.mjs';
import { ReceiverDiagnostics } from './diagnostics.mjs';
import { noReorderDescription } from './h264-sps.mjs';
import { createQualityRenderer, qualityPreset } from './quality-renderer.mjs';
import { setupTranslations, t } from './l10n.mjs';
import { LinkQuality, decodePreferences } from './link-quality.mjs';
setupTranslations();
const qualitySelect = document.querySelector('#quality-select');
let selectedQuality = 'enhanced';
try { selectedQuality = qualityPreset(globalThis.localStorage?.getItem('neoplay.quality')); } catch {}
if (qualitySelect) {
  qualitySelect.value = selectedQuality;
  qualitySelect.addEventListener('change', () => {
    selectedQuality = qualityPreset(qualitySelect.value);
    try { globalThis.localStorage?.setItem('neoplay.quality', selectedQuality); } catch {}
  });
}
const video = document.querySelector('#video'), canvas = document.querySelector('#canvas'), sharpCanvas = document.querySelector('#sharp-canvas'), status = document.querySelector('#status'), emptyState = document.querySelector('#empty-state');
const say = text => { status.textContent = text; if (emptyState) emptyState.hidden = text.startsWith(t('receiving')) || text.startsWith('Receiving'); };
// Two engines. `frames` (v2): WebCodecs pictures and PCM on one sample-accurate
// audio clock, never a seek. `segments` (v1): MediaSource fMP4, the validated
// fallback for browsers without WebCodecs.
const framesCapable = new URLSearchParams(location.search).get('stable') !== '1' && typeof VideoDecoder !== 'undefined' && typeof EncodedVideoChunk !== 'undefined' && typeof AudioWorkletNode !== 'undefined' && typeof AudioContext !== 'undefined';
const segmentsCapable = typeof MediaSource !== 'undefined' && MediaSource.isTypeSupported('video/mp4; codecs="avc1.42E02A, mp4a.40.2"');
let socket, engine = null, audioContext = null, workletReady = null, diagnostics = null, lastDiagnostics = null;
const debug = { error: null, engines: 0, stats: () => engine?.stats() ?? null, diagnostics: () => diagnostics?.export() ?? lastDiagnostics, get audioNode() { return engine?.audioNode ?? null; }, get mode() { return engine?.mode ?? null; }, get audio() { return audioContext ? { state: audioContext.state, sampleRate: audioContext.sampleRate, baseLatency: audioContext.baseLatency, outputLatency: audioContext.outputLatency } : null; } };
const fail = error => { debug.error = error?.message ?? String(error); say(debug.error); };
window.neoplayDebug = debug;
function closeMedia() {
  if (engine && diagnostics) { diagnostics.sample(engine.mode, engine.stats()); lastDiagnostics = diagnostics.export(); }
  engine?.close(); engine = null; diagnostics = null;
}
function sampleDiagnostics() { return engine && diagnostics ? diagnostics.sample(engine.mode, engine.stats()) : null; }
function report() {
  if (socket?.readyState !== WebSocket.OPEN) return;
  const bounds = document.querySelector('#stage').getBoundingClientRect();
  socket.send(JSON.stringify({ type: 'display', ...displayLimits({ width: bounds.width * devicePixelRatio, height: bounds.height * devicePixelRatio, frames: framesCapable }), supported: framesCapable || segmentsCapable }));
}
function acknowledge() { if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'playback', playing: true })); }
async function prepareAudio() {
  if (!audioContext) audioContext = new AudioContext({ sampleRate: 48000, latencyHint: 'interactive' });
  if (!workletReady) workletReady = audioContext.audioWorklet.addModule('/audio-worklet.mjs');
  await workletReady;
  return audioContext;
}
function unlockAudio() {
  prepareAudio().then(audio => {
    if (audio.state !== 'running') audio.resume().catch(() => {});
  }).catch(() => {});
}
// ---- v2: frames engine ------------------------------------------------------
function createFramesEngine(senderNeverReorders) {
  let decoder = null, config = null, node = null, waitKey = true, acknowledged = false, raf = 0, closed = false;
  const queue = []; // decoded VideoFrames waiting for presentation, oldest first
  const clock = { pts: null, updatedAt: 0, lastPts: null, running: false, latencyUs: 0, fillSeconds: 0, targetSeconds: 0.08, ratio: 1, stats: null };
  const counters = { pictures: 0, decoded: 0, presented: 0, freeRun: 0, droppedLate: 0, droppedQueue: 0, flushedPictures: 0, pcmPackets: 0, keyRequests: 0, decodeErrors: 0, recoveries: 0, configurations: 0, reconfigures: 0, audioNodes: 0, discontinuities: 0, spsRestrictions: 0 };
  const link = new LinkQuality();
  let decodedAt = performance.now(), hardwareFallback = null, hardwareFallbacks = 0;
  let settings = null, lastKeyRequest = 0, qualityRenderer = null, qualityFallbacks = 0, qualityBlocked = false;
  const context = canvas.getContext('2d', { alpha: false });
  video.hidden = true; canvas.hidden = false; if (sharpCanvas) sharpCanvas.hidden = true;
  function present() {
    raf = 0; if (closed) return;
    if (!queue.length) return;
    // The audio clock, extrapolated between worklet posts and corrected by the
    // output latency, leads presentation: the oldest due picture is shown, one
    // per display refresh. If the sound stalls (a menu without app sound) for
    // 150 ms, or the pictures run far ahead of the sound, the newest picture is
    // shown on its own pace rather than discarded.
    const now = performance.now();
    let index = queue.length - 1, late = index;
    if (isLive(clock, now)) {
      const pts = audioTime(clock, now, clock.latencyUs), timestamps = queue.map(frame => frame.timestamp);
      ({ index, late } = choose(timestamps, pts));
      if (index < 0) {
        if (timestamps[timestamps.length - 1] - pts <= 500_000) { raf = requestAnimationFrame(present); return; }
        index = late = queue.length - 1; counters.freeRun++;
      }
    } else counters.freeRun++;
    for (let i = 0; i < late; i++) { queue[i].close(); counters.droppedLate++; }
    const frame = queue[index]; queue.splice(0, index + 1);
    if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) { canvas.width = frame.displayWidth; canvas.height = frame.displayHeight; }
    const preset = qualityPreset(selectedQuality);
    let sharpened = false;
    if (preset !== 'original' && sharpCanvas && !qualityBlocked) {
      qualityRenderer ??= createQualityRenderer(sharpCanvas, document.querySelector('#stage'));
      sharpened = qualityRenderer?.draw(frame, preset) === true;
      if (!sharpened) { qualityFallbacks++; qualityBlocked = true; }
    }
    if (sharpened) {
      canvas.hidden = true;
      sharpCanvas.hidden = false;
    } else {
      if (sharpCanvas) sharpCanvas.hidden = true;
      canvas.hidden = false;
      context.drawImage(frame, 0, 0, canvas.width, canvas.height);
    }
    frame.close(); counters.presented++;
    if (!acknowledged) { acknowledged = true; acknowledge(); }
    if (queue.length) raf = requestAnimationFrame(present);
  }
  // A receiver that fell behind resumes at a key picture: it asks the sender for one (through the relay), at most twice a second.
  function requestKey() {
    const now = performance.now(); if (now - lastKeyRequest < 500 || socket?.readyState !== WebSocket.OPEN) return;
    lastKeyRequest = now; counters.keyRequests++; socket.send(JSON.stringify({ type: 'keyframe' }));
  }
  function schedule() { if (!raf) raf = requestAnimationFrame(present); }
  function createDecoder() {
    try { decoder?.close(); } catch {}
    decoder = new VideoDecoder({
      output: frame => { decodedAt = performance.now(); counters.decoded++; queue.push(frame); const drop = overflow(queue.map(f => f.timestamp)); for (let i = 0; i < drop; i++) { queue.shift().close(); counters.droppedQueue++; } schedule(); },
      // A broken reference chain (a shed picture) closes the decoder: rebuild it
      // from the stored configuration and wait for the next key picture.
      error: error => { counters.decodeErrors++; say(`${t('decodeError')}: ${error.message}`); if (!closed && settings) { counters.recoveries++; if (hardwareFallback) { settings = hardwareFallback; hardwareFallback = null; hardwareFallbacks++; } createDecoder(); requestKey(); } },
    });
    decoder.configure(settings); waitKey = true;
  }
  async function configure(packet) {
    const next = parseConfig(packet);
    // Only new native senders promise that every encoder enforces this VT property.
    // Legacy senders (including Build410) leave their description untouched.
    const description = noReorderDescription(next.avcC, { senderNeverReorders });
    if (description !== next.avcC) counters.spsRestrictions++;
    let candidate = null, fallback = null;
    for (const preference of decodePreferences(next, senderNeverReorders)) {
      const option = { codec: next.codec, codedWidth: next.width, codedHeight: next.height, description, optimizeForLatency: true, hardwareAcceleration: preference };
      if ((await VideoDecoder.isConfigSupported(option)).supported) {
        candidate ??= option;
        if (candidate.hardwareAcceleration === 'prefer-hardware' && preference !== 'prefer-hardware') { fallback = option; break; }
        if (candidate.hardwareAcceleration !== 'prefer-hardware') break;
      }
    }
    if (!candidate) throw new Error(`${t('codecError')}: ${next.codec}`);
    if (closed) return;
    // A later configuration (a link tier change) reconfigures in place: the
    // audio ring and its clock continue, only the picture decoder restarts.
    if (config) counters.reconfigures++; counters.configurations++;
    config = next; settings = candidate; hardwareFallback = fallback; decodedAt = performance.now();
    const resolution = document.querySelector('#source-resolution');
    if (resolution) resolution.textContent = `${config.width} × ${config.height}`;
    // Pictures already decoded, and those still inside the old decoder, are
    // presented on the shared clock: a quality change never discards the
    // picture about to be shown. Only the decoder itself is replaced.
    if (decoder && decoder.state === 'configured') { const before = counters.decoded; try { await decoder.flush(); } catch {} counters.flushedPictures += counters.decoded - before; if (closed) return; }
    createDecoder();
    canvas.width = config.width; canvas.height = config.height;
    const audio = await prepareAudio(); if (closed) return;
    if (!node) {
      node = new AudioWorkletNode(audio, 'neoplay-audio', { numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [2] }); counters.audioNodes++;
      node.port.onmessage = ({ data }) => { if (data.type !== 'clock') return; if (data.pts !== null && data.pts !== clock.lastPts) { clock.updatedAt = performance.now(); clock.lastPts = data.pts; } clock.pts = data.pts; clock.running = data.running === true; clock.latencyUs = ((audio.outputLatency || 0) + (audio.baseLatency || 0)) * 1e6; clock.fillSeconds = data.fillSeconds; clock.targetSeconds = data.targetSeconds ?? clock.targetSeconds; clock.ratio = data.ratio; clock.stats = data.stats; schedule(); };
      node.connect(audio.destination);
    }
    node.port.postMessage({ type: 'configure', sampleRate: config.sampleRate, channels: config.channels });
  }
  function picture(packet) {
    if (!decoder || decoder.state !== 'configured') return;
    const { pts, key, discontinuity, data } = parseVideo(packet); counters.pictures++;
    if (discontinuity) { counters.discontinuities++; if (!key) waitKey = true; }
    if (waitKey && !key) return; waitKey = false;
    if (decoder.decodeQueueSize > 8) { if (!key) { waitKey = true; counters.droppedQueue++; requestKey(); return; } }
    decoder.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: pts, data }));
  }
  function sound(packet) {
    if (!node || !config) return;
    const { pts, samples } = parseAudio(packet, config.channels); counters.pcmPackets++;
    node.port.postMessage({ type: 'pcm', pts, samples }, [samples.buffer]);
  }
  const timer = setInterval(() => {
    if (document.visibilityState !== 'hidden' && hardwareFallback && decoder?.decodeQueueSize > 0 && performance.now() - decodedAt > 400) {
      settings = hardwareFallback; hardwareFallback = null; hardwareFallbacks++; createDecoder(); requestKey();
    }
    const row = sampleDiagnostics();
    if (config && row) {
      if (link.sample({ at:performance.now(), queueWaitMs:row.receive.queueWaitMaxMs, decodeQueue:decoder?.decodeQueueSize ?? 0, presented:counters.presented, active:acknowledged, visible:document.visibilityState !== 'hidden' })) requestKey();
      const info = link.snapshot();
      const automatic = document.querySelector('#link-state'), cadence = document.querySelector('#source-fps'), rendered = document.querySelector('#display-resolution');
      if (automatic) automatic.textContent = t(info.state);
      if (cadence) cadence.textContent = `${Math.round(info.fps)} fps`;
      if (rendered) rendered.textContent = sharpCanvas && !sharpCanvas.hidden ? `${sharpCanvas.width} × ${sharpCanvas.height}` : `${canvas.width} × ${canvas.height}`;
    }
    if (config && row) { const known = row.receive.configurations + row.receive.video + row.receive.pcm + row.receive.initializations + row.receive.segments, unknown = row.receive.packets - known; say(`${t('receiving')} · frames · ${config.width}×${config.height} · video ${counters.presented}/${counters.pictures} · PCM ${counters.pcmPackets} · rx ${row.receive.megabitsPerSecond.toFixed(2)} Mbps / ${row.receive.packetsPerSecond.toFixed(0)} pkt/s · wire C${row.receive.configurations} V${row.receive.video} A${row.receive.pcm} U${unknown} · audio cushion ${(clock.fillSeconds * 1000).toFixed(0)}/${(clock.targetSeconds * 1000).toFixed(0)} ms · resample ${clock.ratio.toFixed(3)} · late-video ${counters.droppedLate} · underruns ${clock.stats?.underruns ?? 0} PCM frames · skips ${clock.stats?.skips ?? 0} · recoveries ${counters.recoveries}`); }
  }, 500);
  return {
    mode: 'frames',
    get audioNode() { return node; },
    stats: () => ({ ...counters, quality: selectedQuality, qualityFallbacks, link:link.snapshot(), decoderPreference:settings?.hardwareAcceleration ?? null, hardwareFallbacks, queue: queue.length, audioOutputSampleRate: audioContext?.sampleRate ?? null, clock: { ...clock }, config: config ? { width: config.width, height: config.height, sampleRate: config.sampleRate, channels: config.channels, codec: config.codec } : null }),
    received(packet, at) {
      if (packet[0] === KIND.VIDEO && packet.length >= 9) {
        const view = new DataView(packet.buffer, packet.byteOffset, packet.byteLength);
        link.picture(view.getUint32(1) * 4294967296 + view.getUint32(5), at);
      }
    },
    async receive(packet) {
      if (packet[0] === KIND.CONFIG) await configure(packet);
      else if (packet[0] === KIND.VIDEO) picture(packet);
      else if (packet[0] === KIND.AUDIO) sound(packet);
    },
    close() {
      closed = true; clearInterval(timer); if (raf) cancelAnimationFrame(raf);
      for (const frame of queue) frame.close(); queue.length = 0;
      try { decoder?.close(); } catch {} decoder = null;
      node?.port.postMessage({ type: 'close' }); node?.disconnect(); node = null; // the processor ends itself: no leaked clock
      qualityRenderer?.close(); qualityRenderer = null; if (sharpCanvas) sharpCanvas.hidden = true; canvas.hidden = true; video.hidden = false;
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
    } catch (error) { say(`${t('playbackError')}: ${error.message}`); socket?.close(); release(); }
  }
  function enqueue(data) {
    if (pendingBytes + data.byteLength > MAX_BUFFERED || pending.length >= 32) { say(t('tooSlow')); socket?.close(); release(); return; }
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
      buffer.addEventListener('error', () => { say(t('decodeError')); socket?.close(); });
      pump();
    }, { once: true }); enqueue(data);
  }
  function synchronize() {
    if (closed || !buffer?.buffered.length) return;
    const edge = buffer.buffered.end(buffer.buffered.length - 1), lag = edge - video.currentTime;
    if (!started && edge > 0.35) {
      started = true; video.currentTime = Math.max(buffer.buffered.start(0), edge - 0.3);
      video.play().catch(() => say(t('audioUnlock')));
    } else if (started && lag > 1.25) video.currentTime = Math.max(buffer.buffered.start(0), edge - 0.3);
    video.playbackRate = lag > 0.7 && lag <= 1.25 ? 1.03 : 1;
    if (started) say(`${t('receiving')} · segments · buffer ${Math.max(0, lag).toFixed(2)} s · ${video.videoWidth}×${video.videoHeight} · aspect preserved`);
  }
  const onTime = () => synchronize();
  const timer = setInterval(sampleDiagnostics, 500);
  const onPlaying = () => { if (video.readyState >= 2) acknowledge(); };
  video.addEventListener('timeupdate', onTime); video.addEventListener('playing', onPlaying);
  return {
    mode: 'segments', audioNode: null,
    stats: () => ({ time: video.currentTime, width: video.videoWidth, height: video.videoHeight, frames: video.getVideoPlaybackQuality?.().totalVideoFrames ?? 0 }),
    async receive(packet) {
      if (packet[0] === KIND.INIT) initialize(packet.slice(1).buffer);
      else if (packet[0] === KIND.SEGMENT && mediaSource) enqueue(packet.slice(1).buffer);
    },
    close() { closed = true; clearInterval(timer); video.removeEventListener('timeupdate', onTime); video.removeEventListener('playing', onPlaying); release(); },
  };
}
document.querySelector('#ready').onclick = () => {
  if (framesCapable) unlockAudio(); // user gesture: unlock audio output without blocking video
  if (socket?.readyState === WebSocket.OPEN) { video.play().catch(() => {}); report(); socket.send(JSON.stringify({ type: 'new_pin' })); return; }
  const auth = document.querySelector('#auth').dataset.token;
  socket = new WebSocket(`ws://${location.host}/v1/view?token=${auth}`); socket.binaryType = 'arraybuffer';
  socket.onopen = report;
  let chain = Promise.resolve(), senderNeverReorders = false;
  socket.onmessage = event => {
    try {
      if (typeof event.data === 'string') {
        const message = JSON.parse(event.data);
        if (message.type === 'state') { senderNeverReorders = message.connected === true && message.noFrameReordering === true; document.querySelector('#pin').textContent = message.connected ? '' : message.pin; say(message.connected ? t('receiving') + '…' : t('statusPair')); }
        if (message.type === 'ended') { senderNeverReorders = false; closeMedia(); } return;
      }
      const packet = new Uint8Array(event.data);
      // A new fMP4 initialization restarts MediaSource. A later frames configuration
      // (a link tier change) reconfigures the running frames engine in place: its
      // sound and clock continue; only a protocol change builds a new engine.
      const build = engineFor(packet[0], engine?.mode);
      if (build) { closeMedia(); diagnostics = new ReceiverDiagnostics(); debug.engines++; engine = build === 'frames' ? createFramesEngine(senderNeverReorders) : createSegmentsEngine(); }
      if (!engine) return;
      const current = engine, currentDiagnostics = diagnostics, receivedAt = performance.now();
      currentDiagnostics.received(packet, receivedAt);
      current.received?.(packet, receivedAt);
      chain = chain.then(() => { if (current !== engine) return; currentDiagnostics.processed(receivedAt); return current.receive(packet); }).catch(error => { fail(error); socket?.close(); closeMedia(); });
    } catch (error) { fail(error); socket.close(); closeMedia(); }
  };
  socket.onclose = () => { closeMedia(); say(t('disconnected')); };
  socket.onerror = () => say(t('connectionError'));
};
document.querySelector('#full').onclick = () => document.querySelector('#stage').requestFullscreen().catch(e => say(e.message));
document.querySelector('#stop').onclick = () => { if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'stop' })); };
new ResizeObserver(report).observe(document.querySelector('#stage'));
window.addEventListener('beforeunload', () => socket?.close());

// Open the local viewer immediately so NeoStation iOS can pair without an extra desktop click.
// A real click on Ready remains useful later to unlock browser audio if Chromium requests a user gesture.
if (typeof document.addEventListener === 'function') document.addEventListener('pointerdown', unlockAudio, {capture:true});
queueMicrotask(() => { const ready = document.querySelector('#ready'); if (typeof ready?.click === 'function') ready.click(); });
