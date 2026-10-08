import test from 'node:test';
import assert from 'node:assert/strict';
import {qualityPreset,qualityScale,QUALITY_PRESETS,createQualityRenderer} from '../quality-renderer.mjs';
import {LOCALES,stringsFor,resolveLocale,translationCoverage} from '../l10n.mjs';
import {readFile} from 'node:fs/promises';

test('quality profiles preserve the original low-latency 2D fallback', () => {
  assert.equal(qualityPreset('original'), 'original');
  assert.equal(qualityPreset('enhanced'), 'enhanced');
  assert.equal(qualityPreset('crisp'), 'crisp');
  assert.equal(qualityPreset('__invalid__'), 'enhanced');
  assert.ok(QUALITY_PRESETS.enhanced.strength < QUALITY_PRESETS.crisp.strength);
  assert.equal(createQualityRenderer(null), null);
  assert.equal(createQualityRenderer({getContext:()=>null}), null);
});

test('quality display targets are bounded and retain source aspect ratio', () => {
  assert.deepEqual(qualityScale(1920,884,1280,1), {width:1920,height:884});
  const scaled = qualityScale(1920,884,3200,2);
  assert.equal(scaled.width,3840);
  assert.equal(scaled.height,1768);
  const native = qualityScale(2868,1320,600,1);
  assert.equal(native.width,2868);
  assert.equal(native.height,1320);
});

test('12 NeoStation languages have full labels, with Chinese script distinction', () => {
  assert.equal(LOCALES.length,12);
  const coverage=translationCoverage();
  for(const code of LOCALES){
    assert.equal(coverage[code].complete, true, code);
    assert.equal(coverage[code].expected,49);
    assert.equal(coverage[code].provided,49);
    assert.ok(stringsFor(code).qualityDescription);
  }
  assert.equal(resolveLocale('zh-TW'),'zh-Hant');
  assert.equal(resolveLocale('zh-CN'),'zh');
  assert.equal(resolveLocale('pt-BR'),'pt');
  assert.equal(resolveLocale('fr-FR'),'fr');
  assert.equal(resolveLocale('unknown'),'en');
});

test('every translated UI key exists in every locale and both rendering canvases are present', async () => {
  const html = await readFile(new URL('../index.html', import.meta.url),'utf8');
  assert.match(html, /id="sharp-canvas" hidden/);
  assert.match(html, /id="language-select"/);
  assert.match(html, /id="quality-select"/);
  for(const key of [...html.matchAll(/data-i18n="([^"]+)"/g)].map(m=>m[1])){
    for(const locale of LOCALES) assert.ok(stringsFor(locale)[key],locale+' missing '+key);
  }
  assert.match(html, /#stage>\[hidden\]\{display:none!important\}/);
});