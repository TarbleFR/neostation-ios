import { readFile,writeFile,mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const directory=resolve('dist','installer-tools');
await mkdir(directory,{recursive:true});
const archive=resolve(directory,'nsis.7z'),unpacked=resolve(directory,'nsis');
const expected='9877df902530f96357d13a7a31ae2b9df67f48b11ffc9a1700a7c961574ec5fa';
if(!existsSync(archive)){
 const response=await fetch('https://github.com/electron-userland/electron-builder-binaries/releases/download/nsis-3.0.4.1/nsis-3.0.4.1.7z');
 if(!response.ok)throw new Error('Installer compiler download failed: '+response.status);
 await writeFile(archive,Buffer.from(await response.arrayBuffer()));
}
if(createHash('sha256').update(await readFile(archive)).digest('hex')!==expected)throw new Error('Installer compiler hash mismatch');
execFileSync(resolve('node_modules/7zip-bin/win/x64/7za.exe'),['x',archive,'-o'+unpacked,'-y'],{stdio:'inherit'});
const metadata=JSON.parse(await readFile('package.json','utf8'));
const installer=resolve('dist','NeoPlay-Setup-'+metadata.version+'.exe');
execFileSync(resolve(unpacked,'Bin','makensis.exe'),[
 '/V2','/DAPP_DIR='+resolve('dist','win-unpacked'),'/DOUT_PATH='+installer,
 '/DICON_PATH='+resolve('neoplay-icon.ico'),'/DLICENSE_PATH='+resolve('../../LICENSE.md'),
 '/DREADME_PATH='+resolve('README-WINDOWS.txt'),'/DRUNTIME_UNINSTALL='+resolve('dist','runtime-uninstall.nsh'),
 resolve('windows-installer.nsi')],{stdio:'inherit'});
const bytes=await readFile(installer);
await writeFile(resolve('dist','installer.json'),JSON.stringify({version:metadata.version,sourceCommit:process.env.NEOPLAY_SOURCE_SHA || null,sha256:createHash('sha256').update(bytes).digest('hex'),bytes:bytes.length,embeddedReceiver:true,embeddedPlayer:true,languages:12},null,2));
console.log('NEOPLAY_INSTALLER_BUILT',installer);
