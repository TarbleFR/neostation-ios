// Actual browser decode of fixtures emitted by the production iOS NPMuxer.
// This is not an iPhone radio/ReplayKit/Chromecast hardware test.
import assert from 'node:assert/strict';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { once } from 'node:events';
import { WebSocket } from 'ws';
import { chromium } from 'playwright';
import { createReceiver } from './server.mjs';
const fixture = JSON.parse(await readFile(process.argv[2], 'utf8'));
const receiver = await createReceiver({port:0, host:'127.0.0.1', advertise:false});
let browser, sender;
try {
  browser = await chromium.launch({channel:process.env.NEOPLAY_BROWSER || 'msedge', headless:true});
  const page = await browser.newPage({viewport:{width:1920,height:1080}});
  const failures = [];
  page.on('pageerror', error => failures.push(error.message));
  await page.goto(`http://127.0.0.1:${receiver.port}`);
  await page.click('#ready');
  await page.waitForFunction(() => /^\d{6}$/.test(document.querySelector('#pin').textContent));
  await page.evaluate(() => {
    const video = document.querySelector('video');
    window.probeAudio = new AudioContext();
    const source = window.probeAudio.createMediaElementSource(video), analyser = window.probeAudio.createAnalyser();
    source.connect(analyser); analyser.connect(window.probeAudio.destination); analyser.fftSize = 512;
    window.peakRms = 0;
    window.probeTimer = setInterval(() => { const bytes = new Float32Array(analyser.fftSize); analyser.getFloatTimeDomainData(bytes); const rms = Math.sqrt(bytes.reduce((sum,v) => sum+v*v,0)/bytes.length); window.peakRms = Math.max(window.peakRms,rms); },50);
    window.probeAudio.resume();
  });
  const response = await fetch(`http://127.0.0.1:${receiver.port}/v1/pair`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({v:1,pin:receiver.pin})});
  assert.equal(response.status,200); const grant = await response.json();
  sender = new WebSocket(`ws://127.0.0.1:${receiver.port}/v1/sender`,{headers:{Authorization:`Bearer ${grant.token}`}});
  let acknowledged = false;
  sender.on('message', bytes => { const message = JSON.parse(bytes); if(message.type==='playback' && message.playing) acknowledged = true; });
  await once(sender,'open');
  for (const part of fixture) {
    await new Promise((resolve,reject) => sender.send(Buffer.concat([Buffer.from([part.initial?1:2]),Buffer.from(part.data,'base64')]), error => error?reject(error):resolve()));
    if(!part.initial) await new Promise(resolve => setTimeout(resolve,part.duration*1000));
  }
  await page.waitForFunction(() => document.querySelector('video').currentTime > 3, {timeout:15000});
  const measured = await page.evaluate(() => { const v=document.querySelector('video'); return {time:v.currentTime,width:v.videoWidth,height:v.videoHeight,frames:v.getVideoPlaybackQuality().totalVideoFrames,audioRms:window.peakRms,fit:getComputedStyle(v).objectFit,error:v.error?.message ?? null}; });
  assert.equal(measured.width,640); assert.equal(measured.height,480); assert.equal(measured.fit,'contain'); assert.equal(measured.error,null);
  assert.ok(measured.frames>60); assert.ok(measured.audioRms>0.01); assert.ok(acknowledged);
  await page.setViewportSize({width:3440,height:1440});
  assert.equal(await page.$eval('video',v => getComputedStyle(v).objectFit),'contain');
  const closed=once(sender,'close'); await page.click('#stop'); await closed;
  assert.equal((await (await fetch(`http://127.0.0.1:${receiver.port}/v1/info`)).json()).available,true);
  assert.deepEqual(failures,[]);
  await mkdir('test-output',{recursive:true});
  const report = {platform:process.platform,browser:await browser.version(),fixture:process.argv[2],...measured,acknowledged,physicalIPhone:false,physicalChromecast:false};
  await writeFile('test-output/playback.json', JSON.stringify(report,null,2));
  console.log(JSON.stringify(report));
} finally { sender?.terminate(); await browser?.close(); await receiver.close(); }
