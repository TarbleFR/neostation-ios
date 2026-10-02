import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {readFile,mkdir,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {WebSocket} from 'ws';
import {Bonjour} from 'bonjour-service';
const exe=path.resolve(process.argv[2]);
const folder=path.resolve('test-output','protocol');await mkdir(folder,{recursive:true});
const reportFile=path.join(folder,'server.json');await rm(reportFile,{force:true});
const child=spawn(exe,['--test-server',reportFile],{windowsHide:true,stdio:'ignore'});
const wait=ms=>new Promise(r=>setTimeout(r,ms));
const message=ws=>new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('WebSocket timeout')),5000);ws.once('message',(data,binary)=>{clearTimeout(timer);resolve({data,binary});});});
let viewer,sender;
try{
  let config;
  for(let i=0;i<150;i++){try{config=JSON.parse(await readFile(reportFile,'utf8'));break;}catch{await wait(100);}}
  assert.ok(config,'Test server did not start');
  const base=`http://127.0.0.1:${config.Port}`,wsbase=`ws://127.0.0.1:${config.Port}`;
  const pair=(pin,origin)=>fetch(base+'/v1/pair',{method:'POST',headers:{'Content-Type':'application/json',...(origin?{Origin:origin}:{})},body:JSON.stringify({v:1,pin})});
  assert.equal((await (await fetch(base+'/v1/info')).json()).available,false);
  assert.equal((await fetch(base+'/')).status,403);
  assert.equal((await pair(config.Pin,'https://untrusted.example')).status,403);
  assert.equal((await pair('000000')).status,403);
  assert.equal((await pair('éééééé')).status,403);
  viewer=new WebSocket(wsbase+'/v1/view?token='+config.ViewerToken,{origin:base});const state=message(viewer);await once(viewer,'open');await state;
  viewer.send(JSON.stringify({type:'display',width:1920,height:1080,supported:true}));await wait(50);
  const response=await pair(config.Pin);assert.equal(response.status,200);const grant=await response.json();
  sender=new WebSocket(wsbase+'/v1/sender',{headers:{Authorization:'Bearer '+grant.token}});const ready=message(sender);await once(sender,'open');assert.equal(JSON.parse((await ready).data).type,'ready');await wait(30);
  const payload=Buffer.from([1,0,0,0,8,102,116,121,112]);const media=message(viewer);sender.send(payload);assert.deepEqual((await media).data,payload);
  const resized=message(sender);viewer.send(JSON.stringify({type:'display',width:3440,height:1440,supported:true}));assert.equal(JSON.parse((await resized).data).width,3440);
  const played=message(sender);viewer.send(JSON.stringify({type:'playback',playing:true}));assert.equal(JSON.parse((await played).data).playing,true);
  const close=once(sender,'close');viewer.send(JSON.stringify({type:'stop'}));await close;
  assert.equal((await (await fetch(base+'/v1/info')).json()).available,true);
  const current=await fetch(base+'/?token='+config.ViewerToken);assert.equal(current.status,200);
  const result={passed:true,checks:['localhost UI capability','web-origin rejected','incorrect PIN rejected','Unicode PIN rejected safely','authenticated sender','binary media relay','display renegotiation','playback acknowledgement','disconnect leaves receiver ready'],physicalIPhone:false};
  await writeFile(path.join(folder,'protocol-report.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result));
}finally{sender?.terminate();viewer?.terminate();child.kill();await rm(reportFile,{force:true});}
// Independently test the actual executable's DNS-SD announcement, not a mock.
const advertised=path.join(folder,'mdns-server.json');await rm(advertised,{force:true});
const mdnsChild=spawn(exe,['--test-mdns',advertised],{windowsHide:true,stdio:'ignore'});
const bonjour=new Bonjour();let browser,timer;
try{
  let config;for(let i=0;i<150;i++){try{config=JSON.parse(await readFile(advertised,'utf8'));break;}catch{await wait(100);}}
  assert.ok(config?.MdnsAvailable,'Multicast publisher unavailable');
  const found=await new Promise(resolve=>{timer=setTimeout(()=>resolve(null),12000);browser=bonjour.find({type:'neoplay'},service=>{if(service.txt?.id===config.Id)resolve(service);});});
  assert.ok(found,'Native receiver not found using independent Bonjour browser');
  assert.equal(found.port,config.Port);assert.equal(found.txt.kind,'windows');assert.equal(found.txt.v,'1');assert.ok(found.host.endsWith('.local'));
  const result={passed:true,portMatches:true,protocol:found.protocol,kind:found.txt.kind,version:found.txt.v,scope:'Windows local multicast; iPhone path not yet tested'};
  await writeFile(path.join(folder,'mdns-report.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result));
}finally{clearTimeout(timer);browser?.stop();bonjour.destroy();mdnsChild.kill();await rm(advertised,{force:true});}
