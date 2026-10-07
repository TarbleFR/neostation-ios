import { build } from 'esbuild';
import { inject } from 'postject';
import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';

const output = resolve('dist');
await mkdir(output, {recursive:true});
const executable = resolve(output, process.platform === 'win32' ? 'NeoPlay-Receiver-0.4.1.exe' : 'NeoPlay-Receiver-0.4.1');
await build({entryPoints:['desktop.mjs'], bundle:true, platform:'node', target:'node22', format:'cjs', outfile:resolve(output,'receiver.cjs'),
  define:{'import.meta.url':JSON.stringify(pathToFileURL(resolve('server.mjs')).href)}, external:['bufferutil','utf-8-validate']});
const assets = Object.fromEntries(['index.html','player.mjs','presenter.mjs','protocol.mjs','audio-ring.mjs','audio-worklet.mjs','diagnostics.mjs','h264-sps.mjs'].map(name => [name, resolve(name)]));
const config = {main:resolve(output,'receiver.cjs'), output:resolve(output,'receiver.blob'), disableExperimentalSEAWarning:true, useSnapshot:false, useCodeCache:false, assets};
await writeFile(resolve(output,'sea.json'), JSON.stringify(config));
execFileSync(process.execPath, ['--experimental-sea-config',resolve(output,'sea.json')], {stdio:'inherit'});
await copyFile(process.execPath, executable);
await inject(executable, 'NODE_SEA_BLOB', await readFile(resolve(output,'receiver.blob')), {sentinelFuse:'NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2'});
const bytes = await readFile(executable);
await writeFile(resolve(output,'build.json'), JSON.stringify({version:'0.4.1',sourceCommit:process.env.GITHUB_SHA ?? null,node:process.version,platform:process.platform,architecture:process.arch,sha256:createHash('sha256').update(bytes).digest('hex'),bytes:bytes.length},null,2));
console.log(executable);
