import {mp4Mime, MAX_BUFFERED, displayLimits} from '/protocol.mjs';
const $ = id => document.getElementById(id), video = $('video');
const testing = new URLSearchParams(location.search).has('test');
let socket, mediaSource, buffer, objectURL, queue = [], bytes = 0, generation = 0, started = false, expires = 0, reconnect;
let audioContext, analyser, peak = 0, audioGain, previousFrames = 0, previousTime = performance.now(), measuredFps = 0;
const host = message => window.chrome?.webview?.postMessage(message);
const send = value => { if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(value)); };
const say = text => { $('status').textContent = text; };
function report() { const r = $('stage').getBoundingClientRect(); send({type:'display', ...displayLimits({width:r.width * devicePixelRatio, height:r.height * devicePixelRatio}), supported: typeof MediaSource !== 'undefined' && MediaSource.isTypeSupported('video/mp4; codecs="avc1.42E02A, mp4a.40.2"')}); }
function reset() {
  generation++; queue=[]; bytes=0; started=false; buffer=null; mediaSource=null;
  video.pause(); video.removeAttribute('src'); video.load(); if(objectURL) URL.revokeObjectURL(objectURL); objectURL=null;
  document.body.classList.remove('live'); $('badge').textContent='PRÊT À RECEVOIR'; $('connection').hidden=true;
}
function fatal(message) { say(message); socket?.close(1000,'playback_error'); reset(); $('waiting').hidden=false; }
function pump() {
  if(!buffer || buffer.updating || mediaSource?.readyState!=='open') return;
  try {
    if(buffer.buffered.length && video.currentTime>5 && buffer.buffered.start(0)<video.currentTime-4) {buffer.remove(0,video.currentTime-3);return;}
    const data=queue.shift(); if(data){bytes-=data.byteLength;buffer.appendBuffer(data);}
  } catch(error) {fatal('Lecture interrompue : '+error.message);}
}
function enqueue(data) { if(bytes+data.byteLength>MAX_BUFFERED || queue.length>=32) {fatal('Réception trop lente. Reconnectez NeoPlay.');return;} queue.push(data);bytes+=data.byteLength;pump(); }
function initialize(data) {
  reset(); const epoch=generation, mime=mp4Mime(data);
  if(!MediaSource.isTypeSupported(mime)) throw Error('Ce PC ne prend pas en charge le format vidéo envoyé.');
  $('waiting').hidden=true; $('connection').hidden=false; mediaSource=new MediaSource(); objectURL=URL.createObjectURL(mediaSource);video.src=objectURL;
  mediaSource.addEventListener('sourceopen',()=>{if(epoch!==generation)return;buffer=mediaSource.addSourceBuffer(mime);buffer.mode='segments';buffer.addEventListener('updateend',()=>{pump();sync();});buffer.addEventListener('error',()=>fatal('Erreur de décodage. Reconnectez NeoPlay.'));pump();},{once:true});enqueue(data);
}
function sync() {
  if(!buffer?.buffered.length)return;
  const edge=buffer.buffered.end(buffer.buffered.length-1),lag=edge-video.currentTime;
  if(!started && edge>0.35){started=true;video.currentTime=Math.max(buffer.buffered.start(0),edge-0.3);video.play().catch(()=>say('Cliquez sur l’image pour démarrer la lecture.'));}
  else if(started && lag>1.25)video.currentTime=Math.max(buffer.buffered.start(0),edge-0.3);
  video.playbackRate=lag>0.7 && lag<=1.25 ? 1.03 : 1;
  if(started)say(`${video.videoWidth} × ${video.videoHeight}   ·   ${measuredFps} images/s   ·   Tampon ${Math.max(0,lag).toFixed(2)} s   ·   Proportions conservées`);
}
function connect() {
  clearTimeout(reconnect);
  socket=new WebSocket(`ws://${location.host}/v1/view?token=${$('auth').dataset.token}`);socket.binaryType='arraybuffer';
  socket.onopen=()=>{report();say('Prêt. Sélectionnez ce PC dans NeoStation → NeoPlay.');};
  socket.onmessage=event=>{
    try{
      if(typeof event.data==='string'){
        const m=JSON.parse(event.data);
        if(m.type==='state'){$('pin').textContent=m.pin;expires=m.expires;$('pc').textContent=m.name;$('stop').disabled=!m.connected;$('waiting').hidden=m.connected;if(m.connected){$('connection').hidden=started;say('Connexion établie. Attente du jeu…');}else{say('Prêt. Sélectionnez ce PC dans NeoStation → NeoPlay.');}}
        if(m.type==='ended'){reset();$('waiting').hidden=false;}
        return;
      }
      const packet=new Uint8Array(event.data);if(packet[0]===1)initialize(packet.slice(1).buffer);else if(packet[0]===2 && mediaSource)enqueue(packet.slice(1).buffer);
    }catch(error){fatal(error.message);}
  };
  socket.onclose=()=>{reset();$('waiting').hidden=false;$('stop').disabled=true;say('Reconnexion au récepteur…');reconnect=setTimeout(connect,1500);};
  socket.onerror=()=>say('Connexion locale indisponible. Relancez NeoPlay Receiver.');
}
video.addEventListener('playing',()=>{$('connection').hidden=true;document.body.classList.add('live');$('badge').textContent='EN DIRECT';send({type:'playback',playing:true});});
video.addEventListener('timeupdate',sync); video.onclick=()=>video.play().catch(()=>{});
$('stop').onclick=()=>send({type:'stop'});
$('renew').onclick=()=>send({type:'new_pin'});
$('help').onclick=()=>{$('helpbox').hidden=!$('helpbox').hidden;};$('closehelp').onclick=()=>{$('helpbox').hidden=true;};
$('licenses').onclick=()=>host('licenses');$('logs').onclick=()=>host('logs');$('full').onclick=()=>host('fullscreen');
document.addEventListener('keydown',e=>{if(e.key==='F11'){e.preventDefault();host('fullscreen');}if(e.key==='Escape'){host('exitfullscreen');$('helpbox').hidden=true;}});
$('copy').onclick=()=>{host('copy');$('copy').textContent='Code copié';setTimeout(()=>{$('copy').textContent='Copier le code';},1600);};
$('volume').oninput=()=>{video.volume=Number($('volume').value);video.muted=false;$('mute').textContent='Son';};
$('mute').onclick=()=>{video.muted=!video.muted;$('mute').textContent=video.muted?'Son coupé':'Son';};
new ResizeObserver(report).observe($('stage'));
setInterval(()=>{
  if(expires){const seconds=Math.max(0,Math.floor((expires-Date.now())/1000));$('pinexpiry').textContent=`Code valable ${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`;}
  const now=performance.now(),frames=video.getVideoPlaybackQuality?.().totalVideoFrames??0;
  measuredFps=Math.max(0,Math.round((frames-previousFrames)*1000/(now-previousTime)));previousFrames=frames;previousTime=now;sync();
},1000);
setInterval(report,30000);
if(testing){
  audioContext=new AudioContext();const source=audioContext.createMediaElementSource(video);analyser=audioContext.createAnalyser();audioGain=audioContext.createGain();audioGain.gain.value=0;source.connect(analyser);analyser.connect(audioGain);audioGain.connect(audioContext.destination);analyser.fftSize=512;audioContext.resume();
  setInterval(()=>{const data=new Float32Array(analyser.fftSize);analyser.getFloatTimeDomainData(data);peak=Math.max(peak,Math.sqrt(data.reduce((sum,v)=>sum+v*v,0)/data.length));},50);
}
window.neoPlayMetrics=()=>({width:video.videoWidth,height:video.videoHeight,frames:video.getVideoPlaybackQuality?.().totalVideoFrames??0,audioRms:peak,position:video.currentTime,fit:getComputedStyle(video).objectFit,error:video.error?.message??null,physicalIPhone:false});
window.addEventListener('beforeunload',()=>{clearTimeout(reconnect);socket?.close();});
connect();
