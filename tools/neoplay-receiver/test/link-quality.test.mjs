import test from 'node:test';
import assert from 'node:assert/strict';
import { LinkQuality, decodePreferences } from '../link-quality.mjs';

test('native 4K60 on a stable link never asks to lower source quality', () => {
  const link = new LinkQuality();
  for (let i = 0; i < 3600; i++) {
    const at = i * 1000 / 60;
    link.picture(at * 1000, at + 45 + (i % 3));
    if (i % 30 === 0) assert.equal(link.sample({at:at+48,presented:i}),false);
  }
  assert.equal(link.requests,0); assert.ok(Math.abs(link.rate-60)<0.01);
  assert.ok(link.offsets.length<=360);
});
test('sustained congestion requests bounded feedback and recovers without a session restart', () => {
  const link = new LinkQuality(); link.picture(0,0);
  const requests=[];
  for (let at=500;at<=4000;at+=500) {
    link.picture((at-250)*1000,at);
    if(link.sample({at,presented:at/25}))requests.push(at);
  }
  assert.deepEqual(requests,[1500,2000,2500,3000,3500,4000]);
  assert.ok(requests[2]-requests[0]<=2000);
  link.picture(4500000,4500);
  assert.equal(link.sample({at:4500,presented:180}),false);
  assert.equal(link.state,'linkAutomatic');
});
test('one Wi-Fi spike, a paused game and a hidden window do not trigger feedback', () => {
  const link = new LinkQuality();link.picture(0,0);
  link.picture(250000,500);assert.equal(link.sample({at:500}),false);
  link.picture(1000000,1000);assert.equal(link.sample({at:1000}),false);
  link.picture(20000000,20000);assert.equal(link.sample({at:20000}),false);
  for(let at=20500;at<25000;at+=500){link.picture((at-300)*1000,at);assert.equal(link.sample({at,visible:false}),false);}
  assert.equal(link.requests,0);
});
test('queue congestion requires fresh video and PTS resets rebuild the jitter baseline', () => {
  const link = new LinkQuality();link.picture(1000000,1000);
  assert.equal(link.sample({at:1100,queueWaitMs:300}),false);
  assert.equal(link.sample({at:3000,queueWaitMs:300}),false);
  link.picture(0,4000);assert.equal(link.delayMs,0);
});
test('GPU preference is restricted to guaranteed no-reorder native 4K sources', () => {
  assert.equal(decodePreferences({width:2868,height:1320},true)[0],'prefer-software');
  assert.equal(decodePreferences({width:3840,height:2160},false)[0],'prefer-software');
  assert.equal(decodePreferences({width:3840,height:2160},true)[0],'prefer-hardware');
});
