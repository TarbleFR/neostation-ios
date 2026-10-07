// Actual browser decode of fixtures emitted by the production iOS NPMuxer (v1
// segments) and NPFrameEncoder (v2 frames), through the receiver page in Edge.
// This is not an iPhone radio/ReplayKit/Chromecast hardware test.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { once } from 'node:events';
import { dirname, join } from 'node:path';
import { WebSocket } from 'ws';
import { chromium } from 'playwright';
import { createReceiver } from './server.mjs';
import { parseConfig } from './protocol.mjs';
const fixtureBytes = await readFile(process.argv[2]);
const fixture = JSON.parse(fixtureBytes.toString('utf8'));
const fixtureSha256 = createHash('sha256').update(fixtureBytes).digest('hex');
let noFrameReordering = false;
if (Array.isArray(fixture) && fixture[0]?.kind === 3) {
  try {
    const manifest = JSON.parse(await readFile(join(dirname(process.argv[2]), 'frames-manifest.json'), 'utf8'));
    assert.equal(manifest.schema, 1); assert.equal(manifest.fixtureSha256, fixtureSha256, 'no-reorder guarantee must belong to these exact fixture bytes');
    noFrameReordering = manifest.noFrameReordering === true;
  } catch (error) { if (error.code !== 'ENOENT') throw error; } // older senders make no guarantee
}
const receiver = await createReceiver({port:0, host:'127.0.0.1', advertise:false});
let browser, sender;
try {
  // CI runs Edge on Windows; NEOPLAY_BROWSER_PATH points a local reproduction at any Chromium build.
  browser = await chromium.launch(process.env.NEOPLAY_BROWSER_PATH ? {executablePath:process.env.NEOPLAY_BROWSER_PATH, headless:true, args:['--no-sandbox']} : {channel:process.env.NEOPLAY_BROWSER || 'msedge', headless:true});
  const page = await browser.newPage({viewport:{width:1920,height:1080}});
  const failures = [];
  page.on('pageerror', error => failures.push(error.message));
  page.on('console', message => { if (message.type() === 'error' && !message.text().startsWith('Failed to load resource')) failures.push(`console: ${message.text()}`); });
  page.on('response', response => { if (response.status() >= 400) failures.push(`${response.status()} ${response.url()}`); }); // the page must never request something the relay does not serve
  const status = () => page.evaluate(() => `${document.querySelector('#status').textContent} | error: ${window.neoplayDebug?.error ?? null}`).catch(() => null);
  await page.goto(`http://127.0.0.1:${receiver.port}`);
  await page.click('#ready');
  await page.waitForFunction(() => /^\d{6}$/.test(document.querySelector('#pin').textContent));
  await page.evaluate(() => {
    const video = document.querySelector('video');
    window.probeAudio = new AudioContext();
    const source = window.probeAudio.createMediaElementSource(video), analyser = window.probeAudio.createAnalyser();
    const silent = window.probeAudio.createGain(); silent.gain.value = 0;
    source.connect(analyser); analyser.connect(silent); silent.connect(window.probeAudio.destination); analyser.fftSize = 512;
    window.peakRms = 0;
    window.probeTimer = setInterval(() => { const bytes = new Float32Array(analyser.fftSize); analyser.getFloatTimeDomainData(bytes); const rms = Math.sqrt(bytes.reduce((sum,v) => sum+v*v,0)/bytes.length); window.peakRms = Math.max(window.peakRms,rms); },50);
    window.probeAudio.resume();
  });
  const response = await fetch(`http://127.0.0.1:${receiver.port}/v1/pair`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({v:1,pin:receiver.pin,noFrameReordering})});
  assert.equal(response.status,200); const grant = await response.json();
  sender = new WebSocket(`ws://127.0.0.1:${receiver.port}/v1/sender`,{headers:{Authorization:`Bearer ${grant.token}`}});
  let acknowledged = false, senderClosed = null;
  sender.on('close', (code, reason) => { senderClosed = {code, reason: reason.toString()}; });
  sender.on('message', bytes => { const message = JSON.parse(bytes); if(message.type==='playback' && message.playing) acknowledged = true; });
  await once(sender,'open');
  // frames.json (v2, one packet per picture + PCM) is paced by its packet end
  // times; windows.json (v1 fMP4) by its segment durations.
  const framesFixture = Array.isArray(fixture) && fixture.length > 0 && typeof fixture[0].kind === 'number';
  let measured;
  if (framesFixture) {
    const expected = await page.evaluate(() => ({frames: typeof VideoDecoder !== 'undefined' && typeof AudioWorkletNode !== 'undefined'}));
    assert.equal(expected.frames, true, 'the Windows browser must support WebCodecs and AudioWorklet for the frames protocol');
    await page.evaluate(() => { window.probeTimer2 = setInterval(() => { const node = window.neoplayDebug?.audioNode; if (node && !window.probeNode) { window.probeNode = node; const analyser = window.probeAudio2 = new AnalyserNode(node.context, {fftSize: 512}); node.connect(analyser); window.peakRms2 = 0; setInterval(() => { const bytes = new Float32Array(analyser.fftSize); analyser.getFloatTimeDomainData(bytes); const rms = Math.sqrt(bytes.reduce((sum,v) => sum+v*v,0)/bytes.length); window.peakRms2 = Math.max(window.peakRms2, rms); }, 50); } }, 50); });
    const started = Date.now(); let origin = null, resizedMidStream = false;
    for (const part of fixture) {
      const packet = Buffer.from(part.data,'base64');
      if (part.kind !== 3) { if (origin === null) origin = Date.now(); const due = origin + Math.max(0, part.end - 0.05) * 1000; const wait = due - Date.now(); if (wait > 0) await new Promise(resolve => setTimeout(resolve, wait)); }
      // A window resize (or full screen) in the middle of the stream only reports a new display size: the engine, its audio node and its clock continue.
      if (!resizedMidStream && part.kind === 4 && part.end > 2.5) { resizedMidStream = true; await page.setViewportSize({width:2560,height:1440}); }
      if (senderClosed) throw new Error(`sender closed during ${part.kind} at ${part.end}s: ${JSON.stringify(senderClosed)} status=${await status()} failures=${JSON.stringify(failures)}`);
      await new Promise((resolve,reject) => sender.send(packet, error => error?reject(error):resolve()));
    }
    try { await page.waitForFunction(() => (window.neoplayDebug?.stats()?.presented ?? 0) > 60, null, {timeout:15000}); }
    catch (error) { // the page's own counters explain a stall better than a timeout
      const state = await page.evaluate(() => ({ status: document.querySelector('#status').textContent, error: window.neoplayDebug?.error ?? null, audio: window.neoplayDebug?.audio ?? null, stats: window.neoplayDebug?.stats() ?? null })).catch(e => ({ evaluate: e.message }));
      console.error('NEOPLAY_SMOKE_STALL', JSON.stringify({ state, senderClosed, failures }));
      throw error;
    }
    measured = await page.evaluate(() => { const s = window.neoplayDebug.stats(); const c = document.querySelector('canvas'); return {mode: window.neoplayDebug.mode, engines: window.neoplayDebug.engines, audioNodes: s.audioNodes, configurations: s.configurations, width: c.width, height: c.height, frames: s.presented, decoded: s.decoded, flushedPictures: s.flushedPictures, droppedLate: s.droppedLate, freeRun: s.freeRun, keyRequests: s.keyRequests, reconfigures: s.reconfigures, recoveries: s.recoveries, underruns: s.clock.stats?.underruns ?? null, preroll: s.clock.stats?.preroll ?? null, skips: s.clock.stats?.skips ?? null, jumps: s.clock.stats?.jumps ?? null, gaps: s.clock.stats?.gaps ?? null, trimmed: s.clock.stats?.trimmed ?? null, droppedPCM: s.clock.stats?.dropped ?? null, written: s.clock.stats?.written ?? null, played: s.clock.stats?.played ?? null, cushionTargetMs: Math.round((s.clock.targetSeconds ?? 0) * 1000), audioRms: window.peakRms2 ?? 0, fit: getComputedStyle(c).objectFit, error: s.decodeErrors ? 'decode errors' : null, elapsedMs: 0}; });
    measured.elapsedMs = Date.now() - started;
    const configPackets = fixture.filter(part => part.kind === 3), configs = configPackets.length;
    const last = parseConfig(Buffer.from(configPackets.at(-1).data,'base64')); // the picture size of the last configuration of the fixture
    assert.equal(measured.mode,'frames'); assert.equal(measured.width,last.width); assert.equal(measured.height,last.height); assert.equal(measured.fit,'contain'); assert.equal(measured.error,null);
    assert.equal(measured.configurations, configs); assert.equal(measured.reconfigures, configs - 1, 'every later configuration reconfigures in place'); assert.equal(measured.recoveries, 0);
    assert.equal(measured.engines, 1, 'one engine for the whole session, quality changes and the mid-stream resize included');
    assert.equal(measured.audioNodes, 1, 'one audio node for the whole session: no second audio path, no echo');
    assert.ok(measured.frames>60, 'presented pictures'); assert.ok(measured.droppedLate < measured.frames * 0.1, `late ${measured.droppedLate} of ${measured.frames}`); assert.ok(measured.played>48000, 'played audio frames'); assert.ok(measured.audioRms>0.01, 'audible PCM'); assert.ok(acknowledged);
    // PCM continuity across every quality change: no hole padded with silence,
    // no clock jump, no skip, no overlap trimmed or stale packet dropped
    // (monotonic PCM timestamps), and no underrun beyond 50 ms of output over
    // the whole stream (a quality change used to cost about 230 ms of silence).
    assert.equal(measured.gaps, 0, 'no PCM hole across quality changes'); assert.equal(measured.jumps, 0, 'no audio clock jump'); assert.equal(measured.skips, 0, 'no audio skip');
    assert.equal(measured.trimmed, 0, 'PCM never overlaps: monotonic timestamps'); assert.equal(measured.droppedPCM, 0, 'no stale PCM packet');
    assert.ok(measured.underruns <= 2400, `underruns ${measured.underruns} PCM frames (${(measured.underruns / 48).toFixed(0)} ms)`);
    assert.ok(measured.freeRun <= 6, `pictures left the audio clock ${measured.freeRun} times`); // only before the first PCM packet (2 and 3 on the last CI runs); a stalled clock mid-stream adds many more
    assert.ok(resizedMidStream, 'the resize happened while the stream was running');
    await page.setViewportSize({width:3440,height:1440});
    assert.equal(await page.$eval('canvas',c => getComputedStyle(c).objectFit),'contain');
  } else {
    for (const part of fixture) {
      await new Promise((resolve,reject) => sender.send(Buffer.concat([Buffer.from([part.initial?1:2]),Buffer.from(part.data,'base64')]), error => error?reject(error):resolve()));
      if(!part.initial) await new Promise(resolve => setTimeout(resolve,part.duration*1000));
    }
    await page.waitForFunction(() => document.querySelector('video').currentTime > 3, null, {timeout:15000});
    measured = await page.evaluate(() => { const v=document.querySelector('video'); return {mode:'segments',time:v.currentTime,width:v.videoWidth,height:v.videoHeight,frames:v.getVideoPlaybackQuality().totalVideoFrames,audioRms:window.peakRms,fit:getComputedStyle(v).objectFit,error:v.error?.message ?? null}; });
    assert.equal(measured.width,640); assert.equal(measured.height,480); assert.equal(measured.fit,'contain'); assert.equal(measured.error,null);
    assert.ok(measured.frames>60); assert.ok(measured.audioRms>0.01); assert.ok(acknowledged);
    await page.setViewportSize({width:3440,height:1440});
    assert.equal(await page.$eval('video',v => getComputedStyle(v).objectFit),'contain');
  }
  const closed=once(sender,'close'); await page.click('#stop'); await closed;
  await page.waitForFunction(() => window.neoplayDebug?.mode === null);
  const diagnostics = await page.evaluate(() => window.neoplayDebug.diagnostics());
  assert.ok(diagnostics.samples.length > 0, 'receipt telemetry is retained after stop');
  const totals = diagnostics.samples.at(-1).receive;
  if (framesFixture) {
    assert.equal(totals.configurations, fixture.filter(part => part.kind === 3).length);
    assert.equal(totals.video, fixture.filter(part => part.kind === 4).length);
    assert.equal(totals.pcm, fixture.filter(part => part.kind === 5).length);
    assert.equal(totals.segments, 0, 'v2 has no legacy fMP4 segments');
    if (!noFrameReordering) assert.equal(diagnostics.samples.at(-1).playback.spsRestrictions, 0, 'legacy senders never get an inferred no-reorder promise');
  } else {
    assert.equal(totals.segments, fixture.filter(part => !part.initial).length);
    assert.equal(totals.video, 0); assert.equal(totals.pcm, 0);
  }
  assert.ok(diagnostics.samples.some(row => row.receive.megabitsPerSecond > 0));
  assert.equal((await (await fetch(`http://127.0.0.1:${receiver.port}/v1/info`)).json()).available,true);
  assert.deepEqual(failures,[]);
  await mkdir('test-output',{recursive:true});
  const report = {fixtureSha256,noFrameReordering,spsRestrictions:diagnostics.samples.at(-1).playback.spsRestrictions ?? 0,codeCommit:process.env.GITHUB_SHA || process.env.NEOPLAY_SOURCE_SHA || null,platform:process.platform,browser:await browser.version(),fixture:process.argv[2],...measured,acknowledged,audioRenderedSilently:true,physicalIPhone:false,physicalChromecast:false};
  await writeFile(framesFixture ? 'test-output/playback-frames.json' : 'test-output/playback.json', JSON.stringify(report,null,2));
  await writeFile(framesFixture ? 'test-output/receiver-frames-diagnostics.json' : 'test-output/receiver-segments-diagnostics.json', JSON.stringify(diagnostics,null,2));
  console.log(JSON.stringify(report));
} finally { sender?.terminate(); await browser?.close(); await receiver.close(); }
