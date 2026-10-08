import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('frames canvas remains visible while the hidden video cannot cover it', async () => {
  const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
  assert.match(html, /#stage\s*\{[^}]*position:absolute;inset:0;overflow:hidden/);
  assert.match(html, /#stage>video,#stage>canvas\s*\{[^}]*position:absolute;inset:0;display:block/);
  assert.match(html, /#stage>\[hidden\]\s*\{display:none!important\}/);
  assert.match(html, /<video id="video" playsinline><\/video><canvas id="canvas" hidden><\/canvas>/);
  assert.match(html, /\.empty\[hidden\]\{display:none\}/);
});