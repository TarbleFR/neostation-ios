// End-to-end playback through the shipped Electron window and its own receiver.
// Input fixtures are synthetic; this does not assert physical iPhone validation.
import assert from 'node:assert/strict';
import { _electron as electron } from 'playwright';
import { WebSocket } from 'ws';
import { once } from 'node:events';
import { readFile,writeFile,mkdir } from 'node:fs/promises';
const executable=process.argv[2],fixture=JSON.parse(await readFile(process.argv[3],'utf8'));
let desktop,sender;
const results=[];
try {
 desktop=await electron.launch({executablePath:executable,args:['--playback-proof']});
 const page=await desktop.firstWindow();
 await page.waitForFunction(()=>/^\d{6}$/.test(document.querySelector('#pin').textContent));
 const failures=[];
 page.on('pageerror',e=>failures.push(e.message));
 for (const preset of ['original','enhanced','crisp']) {
  await page.selectOption('#quality-select',preset);
  const host=new URL(page.url()).host;
  const pin=await page.locator('#pin').textContent();
  const response=await fetch('http://'+host+'/v1/pair',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({v:1,pin,noFrameReordering:true})});
  assert.equal(response.status,200);const grant=await response.json();
  sender=new WebSocket('ws://'+host+'/v1/sender',{headers:{Authorization:'Bearer '+grant.token}});
  let acknowledged=false;
  sender.on('message',data=>{const m=JSON.parse(data);if(m.type==='playback'&&m.playing)acknowledged=true;});
  await once(sender,'open');
  await page.evaluate(()=>{
   window.proofPeak=0;window.proofAnalyser=null;
   window.proofTimer=setInterval(()=>{
    const node=window.neoplayDebug?.audioNode;
    if(node&&!window.proofAnalyser){window.proofAnalyser=new AnalyserNode(node.context,{fftSize:512});node.connect(window.proofAnalyser);}
    if(window.proofAnalyser){const values=new Float32Array(512);window.proofAnalyser.getFloatTimeDomainData(values);window.proofPeak=Math.max(window.proofPeak,Math.sqrt(values.reduce((s,v)=>s+v*v,0)/512));}
   },50);
  });
  let origin=null,fullscreenChecked=false;
  for(const part of fixture){
   if(preset==='enhanced'&&!fullscreenChecked&&part.kind===4&&part.end>1.5){await page.click('#full');await page.waitForFunction(()=>document.fullscreenElement?.id==='stage');fullscreenChecked=true;}
   if(part.kind!==3){origin??=Date.now();const wait=origin+Math.max(0,part.end-.05)*1000-Date.now();if(wait>0)await new Promise(r=>setTimeout(r,wait));}
   await new Promise((resolve,reject)=>sender.send(Buffer.from(part.data,'base64'),e=>e?reject(e):resolve()));
  }
  await page.waitForTimeout(150);
  const sample=await page.evaluate(()=>{
   const stats=window.neoplayDebug.stats(),visible=[...document.querySelectorAll('#stage canvas')].filter(c=>!c.hidden);
   clearInterval(window.proofTimer);window.proofAnalyser?.disconnect();
   return {stats,audioRms:window.proofPeak,visible:visible.map(c=>({id:c.id,width:c.width,height:c.height})),nodeExposed:typeof require!=='undefined',userAgent:navigator.userAgent};
  });
  assert.match(sample.userAgent,/Electron\//);
  assert.equal(sample.nodeExposed,false);
  assert.equal(sample.stats.decodeErrors,0);
  assert.equal(sample.stats.config.width,3840);assert.equal(sample.stats.config.height,2160);
  assert.ok(sample.stats.presented>=210,'4K60 should present at least 210 of 240 frames');
  assert.equal(sample.stats.link.requests,0,'clean link must preserve quality');
  assert.equal(sample.stats.audioNodes,1);
  if(preset==='enhanced'){assert.ok(fullscreenChecked);await page.evaluate(()=>document.exitFullscreen());}
  assert.equal(sample.stats.clock.stats?.gaps,0);
  assert.equal(sample.stats.clock.stats?.jumps,0);
  assert.ok(sample.audioRms>.01);
  assert.ok(acknowledged);
  assert.equal(sample.visible.length,1);
  if(preset!=='original')assert.equal(sample.visible[0].id,'sharp-canvas');
  await page.screenshot({path:'test-output/embedded-'+preset+'.png'});
  results.push({preset,acknowledged,...sample});
  const closed=once(sender,'close');await page.click('#stop');await closed;sender=null;
  await page.waitForFunction(()=>window.neoplayDebug.mode===null&&/^\d{6}$/.test(document.querySelector('#pin').textContent));
 }
 assert.deepEqual(failures,[]);
 await mkdir('test-output',{recursive:true});
 await writeFile('test-output/embedded-playback.json',JSON.stringify({version:'0.7.0',embeddedReceiver:true,embeddedPlayer:true,physicalIPhone:false,results},null,2));
 console.log('NEOPLAY_EMBEDDED_4K60_PLAYBACK_OK',JSON.stringify(results.map(r=>({preset:r.preset,presented:r.stats.presented,decoded:r.stats.decoded,decoder:r.stats.decoderPreference,hardwareFallbacks:r.stats.hardwareFallbacks,qualityFallbacks:r.stats.qualityFallbacks,audioRms:r.audioRms}))));
} finally {sender?.terminate();await desktop?.close();}
