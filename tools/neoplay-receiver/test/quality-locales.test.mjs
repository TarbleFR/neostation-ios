import test from 'node:test';
import assert from 'node:assert/strict';
import {qualityPreset,qualityScale,QUALITY_PRESETS,createQualityRenderer,resolutionMode,resolutionScale,RenderBudget} from '../quality-renderer.mjs';
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


test('2K and 4K are true rendering targets, independent of window/capture size', () => {
  assert.equal(resolutionMode('__invalid__'), 'auto');
  assert.equal(resolutionMode('uhd'), 'uhd');
  assert.deepEqual(resolutionScale(1920,1080,'qhd',600,1,400), {width:2560,height:1440});
  assert.deepEqual(resolutionScale(1920,1080,'uhd',600,1,400), {width:3840,height:2160});
  assert.deepEqual(resolutionScale(2868,1320,'uhd',600,1,400), {width:3840,height:1768});
  assert.deepEqual(resolutionScale(2868,1320,'qhd',600,1,400), {width:2560,height:1178});
  assert.deepEqual(resolutionScale(1920,1080,'native',600,1,400), {width:1920,height:1080});
  assert.deepEqual(resolutionScale(1920,1080,'uhd',600,1,400,2048), {width:2048,height:1152});
  assert.deepEqual(resolutionScale(0,1080,'uhd',600,1,400), {width:2,height:2});
});

test('4K rendering steps down without reconfiguring the source, then recovers', () => {
  const budget=new RenderBudget();
  assert.equal(budget.effective('uhd'),'uhd');
  budget.sample({at:0,decoded:0,droppedLate:0});
  budget.sample({at:4000,decoded:240,droppedLate:24});
  assert.equal(budget.effective('uhd'),'qhd');
  budget.sample({at:8000,decoded:480,droppedLate:48});
  assert.equal(budget.effective('uhd'),'native');
  assert.equal(budget.effective('native'),'native');
  budget.sample({at:29000,decoded:1740,droppedLate:48,renderMs:1});
  assert.equal(budget.effective('uhd'),'qhd');
  budget.sample({at:50000,decoded:3000,droppedLate:48,renderMs:1});
  assert.equal(budget.effective('uhd'),'uhd');
  budget.reset();
  assert.equal(budget.effective('uhd'),'uhd');
});

test('stopped video or hidden windows cannot trigger fallback', () => {
  const budget=new RenderBudget();
  budget.sample({at:0,decoded:0,droppedLate:0});
  budget.sample({at:4000,decoded:0,droppedLate:0,renderMs:16});
  assert.equal(budget.effective('uhd'),'uhd');
  budget.sample({at:8000,decoded:240,droppedLate:100,visible:false});
  assert.equal(budget.effective('uhd'),'uhd');
});

test('12 NeoStation languages have full labels, with Chinese script distinction', () => {
  assert.equal(LOCALES.length,12);
  const coverage=translationCoverage();
  for(const code of LOCALES){
    assert.equal(coverage[code].complete, true, code);
    assert.equal(coverage[code].expected,56);
    assert.equal(coverage[code].provided,56);
    assert.ok(stringsFor(code).qualityDescription);
    assert.ok(stringsFor(code).renderDescription);
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
  assert.match(html, /id="resolution-select"/);
  for(const key of [...html.matchAll(/data-i18n="([^"]+)"/g)].map(m=>m[1])){
    for(const locale of LOCALES) assert.ok(stringsFor(locale)[key],locale+' missing '+key);
  }
  assert.match(html, /#stage>\[hidden\]\{display:none!important\}/);
});