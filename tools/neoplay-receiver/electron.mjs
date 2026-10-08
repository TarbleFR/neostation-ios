import { app, BrowserWindow, dialog, session } from 'electron';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { writeFile } from 'node:fs/promises';
import { createReceiver } from './server.mjs';
import { stringsFor } from './l10n.mjs';

app.setName('NeoPlay');
app.setAppUserModelId('fr.tarble.neoplay');
app.setPath('userData', join(process.env.LOCALAPPDATA || app.getPath('appData'), 'NeoPlay', 'Application'));
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');

const smoke = process.argv.includes('--smoke-test');
const proof = process.argv.includes('--playback-proof');
const reportPath = process.argv.find(arg => arg.startsWith('--report='))?.slice(9);
const testMode = smoke || proof;
let window = null, receiver = null, stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  try { await receiver?.close(); } finally { app.quit(); }
}
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => { if (window) { if (window.isMinimized()) window.restore(); window.show(); window.focus(); } });
  app.on('window-all-closed', stop);
  app.on('before-quit', event => { if (receiver && !stopping) { event.preventDefault(); void stop(); } });
  app.whenReady().then(async () => {
    receiver = await createReceiver(testMode ? {port:0,host:'127.0.0.1',advertise:false} : {});
    const origin = 'http://127.0.0.1:' + receiver.port;
    window = new BrowserWindow({
      title:'NeoPlay', width:1366, height:820, minWidth:960, minHeight:640,
      backgroundColor:'#090b10', autoHideMenuBar:true, show:false,
      icon:fileURLToPath(new URL('./neoplay-icon.png', import.meta.url)),
      webPreferences:{nodeIntegration:false,contextIsolation:true,sandbox:true,webSecurity:true}
    });
    session.defaultSession.setPermissionRequestHandler((contents, permission, callback) => callback(permission === 'fullscreen' && contents === window?.webContents));
    window.setMenu(null);
    window.webContents.setWindowOpenHandler(() => ({action:'deny'}));
    window.webContents.on('will-navigate', (event, url) => { if (new URL(url).origin !== origin) event.preventDefault(); });
    window.once('ready-to-show', () => window.show());
    await window.loadURL(origin);
    if (testMode) {
      const capabilities = await window.webContents.executeJavaScript("({webcodecs:typeof VideoDecoder!=='undefined',worklet:typeof AudioWorkletNode!=='undefined',nodeExposed:typeof require!=='undefined',logo:document.querySelector('.logo').complete,version:navigator.userAgent})");
      if (!capabilities.webcodecs || !capabilities.worklet || capabilities.nodeExposed || !capabilities.logo) throw new Error('Embedded player capabilities or isolation failed');
      const result={version:'0.8.0',embeddedReceiver:true,embeddedPlayer:true,port:receiver.port,...capabilities};
      if (reportPath) await writeFile(reportPath,JSON.stringify(result,null,2));
      console.log('NEOPLAY_EMBEDDED_APP_OK',JSON.stringify(result));
      if (smoke) { await stop(); app.exit(0); }
    }
  }).catch(async error => {
    console.error(error);
    if (reportPath) await writeFile(reportPath,JSON.stringify({error:error.message}));
    if (!testMode) dialog.showErrorBox('NeoPlay',stringsFor(app.getLocale()).connectionError+'\n\n'+error.message);
    await stop(); app.exit(1);
  });
}
