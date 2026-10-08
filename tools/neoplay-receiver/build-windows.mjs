import { readFile, writeFile, mkdir, rm, cp, copyFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { rcedit } from 'rcedit';

if (process.platform !== 'win32') throw new Error('Build NeoPlay on Windows');
const metadata=JSON.parse(await readFile('package.json','utf8'));
const output=resolve('dist','win-unpacked');
await rm(output,{recursive:true,force:true});
await mkdir(output,{recursive:true});
await cp(resolve('node_modules/electron/dist'),output,{recursive:true});
await rm(resolve(output,'electron.exe'));
const executable=resolve(output,'NeoPlay.exe');
await copyFile(resolve('node_modules/electron/dist/electron.exe'),executable);
await rcedit(executable,{
  icon:resolve('neoplay-icon.ico'),
  'file-version':metadata.version+'.0','product-version':metadata.version+'.0',
  'version-string':{ProductName:'NeoPlay',FileDescription:'NeoPlay - integrated Windows receiver',CompanyName:'NeoStation',OriginalFilename:'NeoPlay.exe'}
});
const app=resolve(output,'resources','app');
await mkdir(app,{recursive:true});
const files=['electron.mjs','server.mjs','protocol.mjs','discovery.mjs','index.html','player.mjs','presenter.mjs','audio-ring.mjs','audio-worklet.mjs','diagnostics.mjs','h264-sps.mjs','quality-renderer.mjs','link-quality.mjs','l10n.mjs','neostation-logo.svg','neoplay-icon.ico','neoplay-icon.png','README-WINDOWS.txt'];
for(const name of files) await copyFile(resolve(name),resolve(app,name));
await copyFile(resolve('../../LICENSE.md'),resolve(app,'LICENSE.md'));
await writeFile(resolve(app,'package.json'),JSON.stringify({name:'neoplay',version:metadata.version,type:'module',main:'electron.mjs'}));
const packages=['bonjour-service','ws','fast-deep-equal','multicast-dns','dns-packet','thunky','@leichtgewicht/ip-codec'];
for(const name of packages) await cp(resolve('node_modules',name),resolve(app,'node_modules',name),{recursive:true});
const bytes=await readFile(executable);
await writeFile(resolve('dist','build.json'),JSON.stringify({version:metadata.version,sourceCommit:process.env.NEOPLAY_SOURCE_SHA || null,embeddedReceiver:true,embeddedPlayer:true,electron:JSON.parse(await readFile('node_modules/electron/package.json','utf8')).version,platform:process.platform,architecture:process.arch,sha256:createHash('sha256').update(bytes).digest('hex'),bytes:bytes.length},null,2));
console.log('NEOPLAY_WINDOWS_APP_BUILT',executable);

const top=await (await import("node:fs/promises")).readdir(output,{withFileTypes:true});
const uninstall=top.map(item=>item.isDirectory()?'  RMDir /r "$INSTDIR\\'+item.name+'"':'  Delete "$INSTDIR\\'+item.name+'"').join("\n");
await writeFile(resolve("dist","runtime-uninstall.nsh"),uninstall+"\n");
