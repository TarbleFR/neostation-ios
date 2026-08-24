const crypto = require('crypto');

function safeEqual(a, b) {
  const left = Buffer.from(String(a || ''), 'utf8');
  const right = Buffer.from(String(b || ''), 'utf8');
  if (left.length !== right.length) return false;
  return crypto.timingSafeEqual(left, right);
}

function xmlEscape(value) {
  return String(value || '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
}

module.exports = (req, res) => {
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  res.setHeader('X-Robots-Tag', 'noindex, nofollow, noarchive');

  const expectedToken = process.env.INSTALL_TOKEN;
  const receivedToken = req.query?.token;
  if (!expectedToken || !safeEqual(receivedToken, expectedToken)) {
    res.status(403).send('Forbidden');
    return;
  }

  const ipaSourceUrl = process.env.IPA_SOURCE_URL;
  if (!ipaSourceUrl || !ipaSourceUrl.startsWith('https://')) {
    res.status(503).send('IPA_SOURCE_URL is not configured.');
    return;
  }

  const appTitle = process.env.APP_TITLE || 'NeoStation iOS';
  const bundleId = process.env.APP_BUNDLE_ID || 'com.neogamelab.neostation';
  const version = process.env.APP_VERSION || '1.0';
  const host = req.headers['x-forwarded-host'] || req.headers.host;
  const ipaUrl = `https://${host}/app.ipa?token=${encodeURIComponent(expectedToken)}`;

  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${xmlEscape(ipaUrl)}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>${xmlEscape(bundleId)}</string>
        <key>bundle-version</key>
        <string>${xmlEscape(version)}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>${xmlEscape(appTitle)}</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>`;

  res.status(200)
    .setHeader('Content-Type', 'text/xml; charset=utf-8')
    .send(plist);
};
