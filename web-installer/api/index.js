const crypto = require('crypto');

function safeEqual(a, b) {
  const left = Buffer.from(String(a || ''), 'utf8');
  const right = Buffer.from(String(b || ''), 'utf8');
  if (left.length !== right.length) return false;
  return crypto.timingSafeEqual(left, right);
}

function unauthorized(res) {
  res.setHeader('WWW-Authenticate', 'Basic realm="NeoStation iOS Installer", charset="UTF-8"');
  res.status(401).send('Authentication required.');
}

function requireBasicAuth(req, res) {
  const expectedUser = process.env.INSTALLER_USER;
  const expectedPassword = process.env.INSTALLER_PASSWORD;
  if (!expectedUser || !expectedPassword) {
    res.status(503).send('Installer authentication is not configured.');
    return false;
  }

  const header = req.headers.authorization || '';
  if (!header.startsWith('Basic ')) {
    unauthorized(res);
    return false;
  }

  let decoded = '';
  try {
    decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
  } catch (_) {
    unauthorized(res);
    return false;
  }

  const separator = decoded.indexOf(':');
  if (separator < 0) {
    unauthorized(res);
    return false;
  }

  const user = decoded.slice(0, separator);
  const password = decoded.slice(separator + 1);
  if (!safeEqual(user, expectedUser) || !safeEqual(password, expectedPassword)) {
    unauthorized(res);
    return false;
  }
  return true;
}

function htmlEscape(value) {
  return String(value || '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

module.exports = (req, res) => {
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  res.setHeader('X-Robots-Tag', 'noindex, nofollow, noarchive');
  res.setHeader('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");

  if (!requireBasicAuth(req, res)) return;

  const token = process.env.INSTALL_TOKEN;
  const ipaUrl = process.env.IPA_SOURCE_URL;
  const appTitle = process.env.APP_TITLE || 'NeoStation iOS';
  const version = process.env.APP_VERSION || 'Beta';
  const buildLabel = process.env.BUILD_LABEL || 'Private build';

  const host = req.headers['x-forwarded-host'] || req.headers.host;
  const origin = `https://${host}`;
  const ready = Boolean(token && ipaUrl && ipaUrl.startsWith('https://'));
  const manifestUrl = ready
    ? `${origin}/manifest.plist?token=${encodeURIComponent(token)}`
    : '';
  const installUrl = ready
    ? `itms-services://?action=download-manifest&url=${encodeURIComponent(manifestUrl)}`
    : '#';

  const body = `<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="robots" content="noindex,nofollow,noarchive">
  <meta name="theme-color" content="#111318">
  <title>${htmlEscape(appTitle)} — Private Installer</title>
  <style>
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", Inter, system-ui, sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; background: radial-gradient(circle at 30% 0%, #24273d 0, #111318 34%, #090a0d 100%); color: #f7f8fb; display: grid; place-items: center; padding: 24px; }
    main { width: min(620px, 100%); }
    .card { background: rgba(24,27,34,.82); border: 1px solid rgba(255,255,255,.1); border-radius: 28px; padding: 30px; box-shadow: 0 30px 90px rgba(0,0,0,.38); backdrop-filter: blur(18px); }
    .brand { display: flex; gap: 14px; align-items: center; margin-bottom: 24px; }
    .icon { width: 58px; height: 58px; border-radius: 17px; display: grid; place-items: center; font-size: 30px; background: linear-gradient(145deg,#7567ff,#5144e8); box-shadow: inset 0 1px rgba(255,255,255,.22); }
    h1 { font-size: clamp(28px, 6vw, 42px); line-height: 1.02; margin: 0; letter-spacing: -.04em; }
    .eyebrow { color: #9ba3b5; font-size: 13px; text-transform: uppercase; letter-spacing: .12em; margin-bottom: 5px; }
    .meta { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin: 22px 0; }
    .pill { background: rgba(255,255,255,.055); border: 1px solid rgba(255,255,255,.07); border-radius: 15px; padding: 13px 14px; }
    .label { font-size: 12px; color: #8e97aa; margin-bottom: 3px; }
    .value { font-weight: 650; }
    .install { display: block; text-align: center; text-decoration: none; color: white; font-weight: 760; font-size: 18px; padding: 17px 20px; border-radius: 17px; background: linear-gradient(135deg,#6e61ff,#5144e8); box-shadow: 0 12px 30px rgba(81,68,232,.35); margin-top: 8px; }
    .install.disabled { opacity: .42; pointer-events: none; box-shadow: none; }
    .note { margin-top: 18px; font-size: 13px; line-height: 1.55; color: #a9b0bf; }
    .warning { margin-top: 18px; padding: 14px 15px; border-radius: 15px; background: rgba(255,184,77,.09); border: 1px solid rgba(255,184,77,.18); color: #ffd397; font-size: 13px; line-height: 1.45; }
    .ok { color: #7ce6bd; }
    .bad { color: #ffb57e; }
    footer { text-align: center; color: #6f7788; font-size: 12px; margin-top: 16px; }
    @media (max-width: 540px) { .card { padding: 23px; border-radius: 23px; } .meta { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
  <main>
    <section class="card">
      <div class="brand">
        <div class="icon">◈</div>
        <div>
          <div class="eyebrow">Private iOS Installer</div>
          <h1>${htmlEscape(appTitle)}</h1>
        </div>
      </div>
      <div class="meta">
        <div class="pill"><div class="label">Version</div><div class="value">${htmlEscape(version)}</div></div>
        <div class="pill"><div class="label">Build</div><div class="value">${htmlEscape(buildLabel)}</div></div>
        <div class="pill"><div class="label">Distribution</div><div class="value">Sideload / OTA</div></div>
        <div class="pill"><div class="label">Status</div><div class="value ${ready ? 'ok' : 'bad'}">${ready ? 'Prêt à installer' : 'Configuration requise'}</div></div>
      </div>
      <a class="install ${ready ? '' : 'disabled'}" href="${htmlEscape(installUrl)}">Installer NeoStation iOS</a>
      ${ready ? '' : '<div class="warning">Le portail est protégé, mais aucune IPA signée HTTPS n’est encore configurée. Renseigne INSTALL_TOKEN et IPA_SOURCE_URL dans Vercel.</div>'}
      <p class="note">Ouvre cette page sur l’iPhone avec Chrome ou Safari, puis touche le bouton d’installation. iOS récupère ensuite le manifeste et l’IPA via HTTPS.</p>
      <p class="note"><strong>Important :</strong> une IPA non signée ne peut pas être installée par ce bouton. L’IPA publiée doit être signée avec un profil/certificat accepté par l’appareil.</p>
    </section>
    <footer>NeoStation iOS · Private distribution portal · noindex</footer>
  </main>
</body>
</html>`;

  res.status(200).setHeader('Content-Type', 'text/html; charset=utf-8').send(body);
};
