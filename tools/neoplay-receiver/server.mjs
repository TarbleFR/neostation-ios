import http from 'node:http';
import { randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { hostname } from 'node:os';
import { Bonjour } from 'bonjour-service';
import { WebSocketServer, WebSocket } from 'ws';
import { VERSION, MAX_PACKET, MAX_BUFFERED, displayLimits, validatePacket, isInitialization } from './protocol.mjs';
const local = address => ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(address);
const same = (a, b) => { if (typeof a !== 'string' || typeof b !== 'string') return false; const x=Buffer.from(a), y=Buffer.from(b); return x.length === y.length && timingSafeEqual(x,y); };
const token = () => randomBytes(24).toString('hex');
export async function createReceiver({port = 17642, host = '0.0.0.0', advertise = true, name = `NeoPlay — ${hostname()}`, assets = null} = {}) {
  const viewerToken = token(), receiverId = token();
  let pin = String(randomInt(100000, 1000000)), pinExpires = Date.now() + 300000;
  let sender = null, viewer = null, init = null, limits = displayLimits(), ready = false, grant = null, senderNoFrameReordering = false;
  const attempts = new Map();
  const wss = new WebSocketServer({noServer: true, maxPayload: MAX_PACKET, perMessageDeflate: false});
  const json = (res, status, value) => { res.writeHead(status, {'Content-Type':'application/json', 'Cache-Control':'no-store'}); res.end(JSON.stringify(value)); };
  const send = (socket, value) => { if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(value)); };
  const resetPin = () => { pin = String(randomInt(100000, 1000000)); pinExpires = Date.now() + 300000; };
  const uiState = () => ({type:'state', pin, expires:pinExpires, connected: !!sender, noFrameReordering: !!sender && senderNoFrameReordering, name});
  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      if (req.method === 'GET' && url.pathname === '/v1/info') return json(res, 200, {v:VERSION, id:receiverId, name, kind:'windows', available:ready && !sender, ...limits});
      if (req.method === 'POST' && url.pathname === '/v1/pair') {
        // Native clients send no Origin; arbitrary web pages must not pair a LAN receiver.
        if (req.headers.origin) return json(res, 403, {error:'origin'});
        const address = req.socket.remoteAddress, now = Date.now();
        for (const [key, item] of attempts) if (item.until < now) attempts.delete(key);
        const item = attempts.get(address) || {count:0, until:now+60000};
        if (attempts.size >= 128 && !attempts.has(address)) return json(res, 429, {error:'rate_limit'});
        attempts.set(address, item);
        if (++item.count > 5) return json(res, 429, {error:'rate_limit'});
        let body = ''; for await (const chunk of req) { body += chunk; if (body.length > 1024) { req.destroy(); return; } }
        let value; try { value = JSON.parse(body); } catch { return json(res, 400, {error:'json'}); }
        if (value.v !== VERSION || now > pinExpires || !same(value.pin, pin)) return json(res, 403, {error:'pairing'});
        if (!ready || sender) return json(res, 409, {error:'receiver_not_ready'});
        grant = {token:token(), address, until:now+30000, noFrameReordering:value.noFrameReordering === true};
        return json(res, 200, {v:VERSION, token:grant.token, ...limits});
      }
      if (!local(req.socket.remoteAddress) || !['localhost','127.0.0.1','[::1]'].some(h => req.headers.host === `${h}:${server.address().port}`)) return json(res, 403, {error:'local_ui_only'});
      const assetPaths = {'/':'index.html', '/player.mjs':'player.mjs', '/presenter.mjs':'presenter.mjs', '/protocol.mjs':'protocol.mjs', '/audio-ring.mjs':'audio-ring.mjs', '/audio-worklet.mjs':'audio-worklet.mjs', '/diagnostics.mjs':'diagnostics.mjs', '/h264-sps.mjs':'h264-sps.mjs'};
      if (req.method === 'GET' && url.pathname === '/favicon.ico') { res.writeHead(204, {'Cache-Control':'max-age=86400'}); return res.end(); } // browsers ask; no 404 in the page
      if (req.method !== 'GET' || !assetPaths[url.pathname]) return json(res, 404, {error:'not_found'});
      const assetName = assetPaths[url.pathname];
      let data = assets ? assets[assetName] : await readFile(new URL(assetName, import.meta.url), 'utf8');
      if (url.pathname === '/') data = data.replace('__VIEWER_TOKEN__', viewerToken);
      res.writeHead(200, {'Content-Type':url.pathname === '/' ? 'text/html; charset=utf-8':'text/javascript', 'Cache-Control':'no-store', 'X-Content-Type-Options':'nosniff', 'Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self' ws://127.0.0.1:* ws://localhost:*; worker-src 'self'; media-src blob:; frame-ancestors 'none'"}); res.end(data);
    } catch { if (!res.headersSent) json(res, 500, {error:'request_failed'}); else res.end(); }
  });
  server.requestTimeout = 10000; server.headersTimeout = 10000;
  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://localhost');
    const isViewer = url.pathname === '/v1/view' && local(req.socket.remoteAddress) && same(url.searchParams.get('token'), viewerToken) && !viewer;
    const isSender = url.pathname === '/v1/sender' && !req.headers.origin && ready && !sender && grant && grant.until > Date.now() && grant.address === req.socket.remoteAddress && same(req.headers.authorization, `Bearer ${grant.token}`);
    if (!isViewer && !isSender) { socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); return; }
    wss.handleUpgrade(req, socket, head, ws => {
      ws.on('error', () => ws.close());
      if (isViewer) {
        viewer = ws; send(ws, uiState());
        ws.on('message', (data, binary) => {
          if (binary || data.length > 2048) { ws.close(1008); return; }
          try {
            const message = JSON.parse(data);
            if (message.type === 'display') { limits = displayLimits(message); ready = message.supported === true; send(sender, {type:'display', ...limits}); }
            if (message.type === 'new_pin' && !sender) { resetPin(); send(ws, uiState()); }
            if (message.type === 'playback') send(sender, {type:'playback', playing:message.playing === true});
            if (message.type === 'keyframe') send(sender, {type:'keyframe'}); // the viewer fell behind: the sender sends a key picture
            if (message.type === 'stop') sender?.close(1000, 'receiver_stop');
          } catch { ws.close(1008); }
        });
        ws.on('close', () => { if (viewer === ws) { viewer = null; ready = false; sender?.close(1000, 'viewer_closed'); } });
      } else {
        sender = ws; senderNoFrameReordering = grant.noFrameReordering; grant = null; init = null; send(ws, {type:'ready', v:VERSION, ...limits}); send(viewer, uiState());
        ws.on('message', (data, binary) => {
          try {
            if (!binary) throw new Error('Binary media required');
            const kind = validatePacket(data);
            if (isInitialization(kind)) init = data;
            if (!init || !viewer || viewer.bufferedAmount > MAX_BUFFERED) throw new Error('Receiver backpressure');
            viewer.send(data, {binary:true});
          } catch { ws.close(1008, 'media_or_backpressure'); }
        });
        ws.on('close', () => { if (sender === ws) { sender = null; senderNoFrameReordering = false; init = null; resetPin(); send(viewer, {type:'ended'}); send(viewer, uiState()); } });
      }
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, resolve); });
  const actualPort = server.address().port;
  const bonjour = advertise ? new Bonjour() : null;
  bonjour?.publish({name, type:'neoplay', protocol:'tcp', port:actualPort, txt:{v:'1', kind:'windows', id:receiverId}});
  return {port:actualPort, viewerToken, get pin(){return pin;}, async close(){ wss.clients.forEach(s => s.terminate()); wss.close(); bonjour?.unpublishAll(); bonjour?.destroy(); await new Promise(resolve => server.close(resolve)); }};
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const receiver = await createReceiver();
  console.log(`NeoPlay Receiver: http://127.0.0.1:${receiver.port}\nOpen this address in Edge or Chrome, then click Ready. Local trusted networks only.`);
  const stop = async () => { await receiver.close(); process.exit(0); };
  process.once('SIGINT', stop); process.once('SIGTERM', stop);
}
