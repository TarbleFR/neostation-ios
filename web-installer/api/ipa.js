const crypto = require('crypto');

function safeEqual(a, b) {
  const left = Buffer.from(String(a || ''), 'utf8');
  const right = Buffer.from(String(b || ''), 'utf8');
  if (left.length !== right.length) return false;
  return crypto.timingSafeEqual(left, right);
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

  res.status(302).setHeader('Location', ipaSourceUrl).end();
};
