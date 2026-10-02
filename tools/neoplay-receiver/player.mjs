import { mp4Mime, MAX_BUFFERED, displayLimits } from './protocol.mjs';
const video = document.querySelector('#video'), status = document.querySelector('#status');
let socket, mediaSource, buffer, objectURL, pending = [], pendingBytes = 0, generation = 0, started = false;
const say = text => { status.textContent = text; };
function closeMedia() {
  generation++; pending = []; pendingBytes = 0; started = false; buffer = null;
  video.pause(); video.removeAttribute('src'); video.load();
  if (objectURL) URL.revokeObjectURL(objectURL);
  objectURL = null; mediaSource = null;
}
function report() {
  if (socket?.readyState !== WebSocket.OPEN) return;
  const bounds = document.querySelector('#stage').getBoundingClientRect();
  socket.send(JSON.stringify({type:'display', ...displayLimits({width:bounds.width * devicePixelRatio, height:bounds.height * devicePixelRatio}), supported: typeof MediaSource !== 'undefined' && MediaSource.isTypeSupported('video/mp4; codecs="avc1.42E02A, mp4a.40.2"')}));
}
function pump() {
  if (!buffer || buffer.updating || mediaSource.readyState !== 'open') return;
  try {
    if (buffer.buffered.length && video.currentTime > 5 && buffer.buffered.start(0) < video.currentTime - 4) { buffer.remove(0, video.currentTime - 3); return; }
    const data = pending.shift(); if (data) { pendingBytes -= data.byteLength; buffer.appendBuffer(data); }
  } catch (error) { say(`Playback failed: ${error.message}`); socket?.close(); closeMedia(); }
}
function enqueue(data) {
  if (pendingBytes + data.byteLength > MAX_BUFFERED || pending.length >= 32) { say('Receiver too slow. Reconnect at a lower resolution.'); socket?.close(); closeMedia(); return; }
  pending.push(data); pendingBytes += data.byteLength; pump();
}
function initialize(data) {
  closeMedia(); const epoch = generation; const mime = mp4Mime(data);
  if (!MediaSource.isTypeSupported(mime)) throw new Error(`Codec unavailable: ${mime}`);
  mediaSource = new MediaSource(); objectURL = URL.createObjectURL(mediaSource); video.src = objectURL;
  mediaSource.addEventListener('sourceopen', () => {
    if (epoch !== generation) return;
    buffer = mediaSource.addSourceBuffer(mime); buffer.mode = 'segments';
    buffer.addEventListener('updateend', () => { pump(); synchronize(); });
    buffer.addEventListener('error', () => { say('Media decoding failed.'); socket?.close(); });
    pump();
  }, {once:true}); enqueue(data);
}
function synchronize() {
  if (!buffer?.buffered.length) return;
  const edge = buffer.buffered.end(buffer.buffered.length - 1), lag = edge - video.currentTime;
  if (!started && edge > 0.35) {
    started = true; video.currentTime = Math.max(buffer.buffered.start(0), edge - 0.3);
    video.play().catch(() => say('Click Ready again to allow audio playback.'));
  } else if (started && lag > 1.25) video.currentTime = Math.max(buffer.buffered.start(0), edge - 0.3);
  video.playbackRate = lag > 0.7 && lag <= 1.25 ? 1.03 : 1;
  if (started) say(`Receiving · buffer ${Math.max(0, lag).toFixed(2)} s · ${video.videoWidth}×${video.videoHeight} · aspect preserved`);
}
video.addEventListener('timeupdate', synchronize);
document.querySelector('#ready').onclick = () => {
  if (socket?.readyState === WebSocket.OPEN) { video.play().catch(() => {}); report(); socket.send(JSON.stringify({type:'new_pin'})); return; }
  const auth = document.querySelector('#auth').dataset.token;
  socket = new WebSocket(`ws://${location.host}/v1/view?token=${auth}`); socket.binaryType = 'arraybuffer';
  socket.onopen = report;
  socket.onmessage = event => {
    try {
      if (typeof event.data === 'string') {
        const message = JSON.parse(event.data);
        if (message.type === 'state') { document.querySelector('#pin').textContent = message.connected ? '' : message.pin; say(message.connected ? 'Receiving…' : 'Select this PC in NeoPlay. PIN valid for five minutes.'); }
        if (message.type === 'ended') closeMedia(); return;
      }
      const packet = new Uint8Array(event.data);
      if (packet[0] === 1) initialize(packet.slice(1).buffer);
      else if (packet[0] === 2 && mediaSource) enqueue(packet.slice(1).buffer);
    } catch (error) { say(error.message); socket.close(); closeMedia(); }
  };
  socket.onclose = () => { closeMedia(); say('Receiver disconnected. Click Ready to restart.'); };
  socket.onerror = () => say('Cannot reach local NeoPlay Receiver.');
};
document.querySelector('#full').onclick = () => document.querySelector('#stage').requestFullscreen().catch(e => say(e.message));
document.querySelector('#stop').onclick = () => { if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({type:'stop'})); };
new ResizeObserver(report).observe(document.querySelector('#stage'));
window.addEventListener('beforeunload', () => socket?.close());
