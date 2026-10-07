import test from 'node:test';
import assert from 'node:assert/strict';
import { inspectSps, noReorderDescription } from '../h264-sps.mjs';
// Exact avcC from production iOS fixture f5478b, 640x480 High profile, no B pictures.
const captured = Uint8Array.from(Buffer.from('0164001fffe100142764001fac5230280f6c05a8101011856bdef80801000428fe09cb', 'hex'));
const sps = avc => avc.subarray(8, 8 + avc[6] * 256 + avc[7]);
const enabled = { senderNeverReorders: true };
// Minimal independent Baseline SPS builder: 640x480, two reference pictures.
// null omits VUI entirely; a number supplies an explicit reorder restriction.
function baselineDescription(reorder = null) {
  const bits = [];
  const u = (value, count) => { for (let i = count - 1; i >= 0; i--) bits.push((value >>> i) & 1); };
  const ue = value => { const n = Math.floor(Math.log2(value + 1)) + 1; u(0, n - 1); u(value + 1, n); };
  u(0x67, 8); u(66, 8); u(0, 8); u(31, 8); ue(0); ue(0); ue(2); ue(2); u(0, 1); ue(39); ue(29); u(1, 1); u(1, 1); u(0, 1);
  u(reorder === null ? 0 : 1, 1);
  if (reorder !== null) { u(0, 8); u(1, 1); u(1, 1); ue(0); ue(0); ue(16); ue(16); ue(reorder); ue(2); }
  u(1, 1); while (bits.length % 8) u(0, 1);
  const nal = []; let zeros = 0;
  for (let at = 0; at < bits.length; at += 8) {
    const byte = bits.slice(at, at + 8).reduce((value, bit) => value * 2 + bit, 0);
    if (zeros >= 2 && byte <= 3) { nal.push(3); zeros = 0; }
    nal.push(byte); zeros = byte === 0 ? zeros + 1 : 0;
  }
  return Uint8Array.from([1, 66, 0, 31, 255, 225, nal.length >> 8, nal.length & 255, ...nal, 1, 0, 4, 0x28, 0xfe, 9, 0xcb]);
}
test('missing VUI restriction gets zero reorder without changing picture format or PPS', () => {
  const before = inspectSps(sps(captured)); assert.equal(before.restriction, false); assert.equal(before.maxRef, 2);
  const fixed = noReorderDescription(captured, enabled), after = inspectSps(sps(fixed));
  assert.notDeepEqual(fixed, captured); assert.equal(after.restriction, true); assert.equal(after.reorder, 0); assert.equal(after.dpb, 2);
  for (const key of ['profile', 'level', 'width', 'height', 'maxRef', 'progressive']) assert.equal(after[key], before[key]);
  assert.deepEqual(fixed.subarray(8 + sps(fixed).length), captured.subarray(8 + sps(captured).length));
  assert.deepEqual(fixed.subarray(0, 6), captured.subarray(0, 6));
  assert.equal(noReorderDescription(fixed, enabled), fixed, 'existing explicit restriction preserved');
  assert.equal(noReorderDescription(captured), captured, 'generic streams must opt in explicitly');
});
test('truncated AVC/SPS, invalid lengths and unknown profiles are preserved without throwing', () => {
  for (let i = 0; i < captured.length; i++) { const truncated = captured.slice(0, i); assert.equal(noReorderDescription(truncated, enabled), truncated); }
  const malformed = captured.slice(); malformed[6] = 255; assert.equal(noReorderDescription(malformed, enabled), malformed);
  const unknown = captured.slice(); unknown[9] = 255; assert.equal(noReorderDescription(unknown, enabled), unknown);
  for (const [offset, value] of [[8, 0x07], [10, 3], [4, 3], [4, 254], [5, 1], [31, 0x27]]) {
    const invalid = captured.slice(); invalid[offset] = value;
    assert.equal(noReorderDescription(invalid, enabled), invalid, `invalid header at ${offset} preserved`);
  }
  assert.throws(() => inspectSps(new Uint8Array([0x67])));
  assert.throws(() => inspectSps(Uint8Array.from([...sps(captured), 0])), /trailing/);
  for (const byte of [0, 1, 2]) assert.throws(() => inspectSps(Uint8Array.from([0x67, 0, 0, byte])), /emulation/);
});
test('absent VUI gets a minimal restriction and explicit nonzero reordering stays untouched', () => {
  const absent = baselineDescription(), before = inspectSps(sps(absent));
  assert.equal(before.vui, false); assert.equal(before.maxRef, 2);
  const fixed = noReorderDescription(absent, enabled), after = inspectSps(sps(fixed));
  assert.notEqual(fixed, absent); assert.equal(after.vui, true); assert.equal(after.reorder, 0); assert.equal(after.dpb, 2);
  for (const reorder of [0, 1, 2]) {
    const explicit = baselineDescription(reorder);
    assert.equal(inspectSps(sps(explicit)).reorder, reorder);
    assert.equal(noReorderDescription(explicit, enabled), explicit);
  }
});
