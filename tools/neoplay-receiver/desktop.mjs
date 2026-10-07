import { isSea, getAsset } from 'node:sea';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { createReceiver } from './server.mjs';

async function main() {
  const assets = isSea() ? Object.fromEntries(['index.html','player.mjs','presenter.mjs','protocol.mjs','audio-ring.mjs','audio-worklet.mjs','diagnostics.mjs','h264-sps.mjs'].map(name => [name,getAsset(name,'utf8')])) : null;
  const smoke = process.argv.includes('--smoke-test');
  const receiver = await createReceiver({assets, ...(smoke ? {port:0,host:'127.0.0.1',advertise:false} : {})});
  if (smoke) {
    const base = `http://127.0.0.1:${receiver.port}`;
    for (const path of ['/','/player.mjs','/presenter.mjs','/protocol.mjs','/audio-ring.mjs','/audio-worklet.mjs','/diagnostics.mjs','/h264-sps.mjs']) {
      const response = await fetch(base+path);
      if (!response.ok || !(await response.text()).length) throw new Error(`Embedded asset unavailable: ${path}`);
    }
    await receiver.close(); console.log('NEOPLAY_PACKAGED_ASSETS_OK'); return;
  }
  const url = `http://127.0.0.1:${receiver.port}`;
  console.log(`NeoPlay Receiver 0.4.0\n${url}\nKeep this window open while playing.`);
  const roots = [process.env.ProgramFiles, process.env['ProgramFiles(x86)'], process.env.LOCALAPPDATA].filter(Boolean);
  const browser = roots.flatMap(root => ['Microsoft/Edge/Application/msedge.exe','Google/Chrome/Application/chrome.exe'].map(path => join(root,path))).find(existsSync);
  if (browser) spawn(browser, [`--app=${url}`], {detached:true,stdio:'ignore'}).unref();
  else if (process.platform === 'win32') spawn('cmd.exe',['/d','/c','start','',url], {stdio:'ignore'}).unref();
  const stop = async () => { await receiver.close(); process.exit(0); };
  process.once('SIGINT',stop); process.once('SIGTERM',stop);
}
main().catch(error => { console.error(`NeoPlay Receiver: ${error.message}`); process.exitCode = 1; });
