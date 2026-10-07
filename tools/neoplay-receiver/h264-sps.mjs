// NeoPlay v2 sends H.264 without picture reordering (NPFrameEncoder sets
// AllowFrameReordering=false). Some VideoToolbox encoders omit the VUI DPB
// restriction: H.264 E.2.1 then permits decoders to infer the level's full DPB.
// On Windows this held ~15 pictures despite optimizeForLatency. Supply the
// missing restriction only for this explicit no-reordering sender contract.
// Preserve existing restrictions, unsupported syntax and malformed bytes.
class Reader {
  constructor(bytes) { this.bytes = bytes; this.pos = 0; }
  bit() { if (this.pos >= this.bytes.length * 8) throw new Error('Truncated SPS'); const value = (this.bytes[this.pos >> 3] >> (7 - (this.pos & 7))) & 1; this.pos++; return value; }
  u(n) { let value = 0; for (let i = 0; i < n; i++) value = value * 2 + this.bit(); return value; }
  ue() { let zeros = 0; while (!this.bit()) if (++zeros > 31) throw new Error('Invalid Exp-Golomb'); return 2 ** zeros - 1 + this.u(zeros); }
  se() { const value = this.ue(); return value & 1 ? (value + 1) / 2 : -value / 2; }
  trailing() { if (this.bit() !== 1 || this.bytes.length * 8 - this.pos > 7) throw new Error('Invalid trailing bits'); while (this.pos < this.bytes.length * 8) if (this.bit()) throw new Error('Unsupported SPS tail'); }
}
function unescape(nal) {
  const bytes = []; let zeros = 0;
  for (let i = 0; i < nal.length; i++) {
    const value = nal[i];
    if (zeros >= 2 && value === 3) { if (i + 1 >= nal.length || nal[i + 1] > 3) throw new Error('Invalid emulation prevention'); zeros = 0; continue; }
    if (zeros >= 2 && value <= 2) throw new Error('Missing emulation prevention');
    bytes.push(value); zeros = value === 0 ? zeros + 1 : 0;
  }
  return Uint8Array.from(bytes);
}
function escape(bytes) {
  const nal = []; let zeros = 0;
  for (const value of bytes) { if (zeros >= 2 && value <= 3) { nal.push(3); zeros = 0; } nal.push(value); zeros = value === 0 ? zeros + 1 : 0; }
  return Uint8Array.from(nal);
}
function scaling(r, size) { let last = 8, next = 8; for (let i = 0; i < size; i++) { if (next) { const delta = r.se(); if (delta < -128 || delta > 127) throw new Error('Invalid scaling delta'); next = (last + delta + 256) % 256; } last = next || last; } }
function hrd(r) { const count = r.ue() + 1; if (count > 32) throw new Error('Invalid HRD'); r.u(8); for (let i = 0; i < count; i++) { r.ue(); r.ue(); r.bit(); } r.u(20); }
export function inspectSps(nal) {
  if (!nal.length || nal.length > 65535 || (nal[0] & 0x9f) !== 7 || !(nal[0] & 0x60)) throw new Error('Invalid SPS NAL');
  const rbsp = unescape(nal), r = new Reader(rbsp); r.u(8);
  const profile = r.u(8); if (r.u(8) & 3) throw new Error('Invalid reserved bits'); const level = r.u(8); if (r.ue() > 31) throw new Error('Invalid SPS ID');
  if (![66, 77, 88, 100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].includes(profile)) throw new Error('Unsupported profile');
  if (![66, 77, 88].includes(profile)) {
    const chroma = r.ue(); if (chroma > 3) throw new Error('Invalid chroma'); if (chroma === 3) r.bit();
    if (r.ue() > 6 || r.ue() > 6) throw new Error('Invalid bit depth'); r.bit();
    if (r.bit()) for (let i = 0; i < (chroma !== 3 ? 8 : 12); i++) if (r.bit()) scaling(r, i < 6 ? 16 : 64);
  }
  if (r.ue() > 12) throw new Error('Invalid frame numbering'); const poc = r.ue();
  if (poc === 0) { if (r.ue() > 12) throw new Error('Invalid POC width'); }
  else if (poc === 1) { r.bit(); r.se(); r.se(); const count = r.ue(); if (count > 255) throw new Error('Invalid POC'); for (let i = 0; i < count; i++) r.se(); }
  else if (poc !== 2) throw new Error('Unsupported POC');
  const maxRef = r.ue(); r.bit(); const width = (r.ue() + 1) * 16, height = (r.ue() + 1) * 16;
  const progressive = r.bit() === 1; if (!progressive) r.bit(); r.bit();
  if (r.bit()) { r.ue(); r.ue(); r.ue(); r.ue(); }
  const vuiBit = r.pos, vui = r.bit() === 1;
  const info = { profile, level, maxRef, width, height, progressive, vuiBit, vui, restrictionBit: null, restriction: false, reorder: null, dpb: null, rbsp };
  if (vui) {
    if (r.bit() && r.u(8) === 255) { r.u(16); r.u(16); }
    if (r.bit()) r.bit();
    if (r.bit()) { r.u(3); r.bit(); if (r.bit()) { r.u(8); r.u(8); r.u(8); } }
    if (r.bit()) { r.ue(); r.ue(); }
    if (r.bit()) { r.u(32); r.u(32); r.bit(); }
    const nalHrd = r.bit(); if (nalHrd) hrd(r); const vclHrd = r.bit(); if (vclHrd) hrd(r); if (nalHrd || vclHrd) r.bit(); r.bit();
    info.restrictionBit = r.pos; info.restriction = r.bit() === 1;
    if (info.restriction) { r.bit(); r.ue(); r.ue(); r.ue(); r.ue(); info.reorder = r.ue(); info.dpb = r.ue(); }
  }
  r.trailing(); return info;
}
function restrictSps(nal) {
  const info = inspectSps(nal);
  if (info.restriction || !info.progressive || info.maxRef > 16) return nal;
  const bits = [], r = new Reader(info.rbsp);
  const u = (value, count) => { for (let i = count - 1; i >= 0; i--) bits.push(Math.floor(value / 2 ** i) & 1); };
  const ue = value => { const length = Math.floor(Math.log2(value + 1)) + 1; u(0, length - 1); u(value + 1, length); };
  for (let i = 0; i < (info.vui ? info.restrictionBit : info.vuiBit); i++) u(r.bit(), 1);
  if (!info.vui) { u(1, 1); u(0, 8); } // empty VUI: aspect/overscan/signal/chroma/timing/HRD/pic_struct
  u(1, 1); u(1, 1); ue(0); ue(0); ue(16); ue(16); ue(0); ue(Math.max(1, info.maxRef));
  u(1, 1); while (bits.length % 8) u(0, 1);
  const bytes = new Uint8Array(bits.length / 8); bits.forEach((value, i) => { bytes[i >> 3] |= value << (7 - (i & 7)); });
  return escape(bytes);
}
export function noReorderDescription(avcC, { senderNeverReorders = false } = {}) {
  if (!senderNeverReorders || avcC.length < 7 || avcC.length > 65535 || avcC[0] !== 1 || (avcC[4] & 0xfc) !== 0xfc || (avcC[4] & 3) === 2 || (avcC[5] & 0xe0) !== 0xe0) return avcC;
  try {
    const count = avcC[5] & 31; if (!count) return avcC;
    let at = 6, changed = false; const result = [...avcC.subarray(0, 6)];
    const take = () => { if (at + 2 > avcC.length) throw new Error('Truncated parameter length'); const size = avcC[at] * 256 + avcC[at + 1]; at += 2; if (!size || at + size > avcC.length) throw new Error('Truncated parameter set'); const bytes = avcC.subarray(at, at + size); at += size; return bytes; };
    for (let i = 0; i < count; i++) { const sps = take(), fixed = restrictSps(sps); changed ||= fixed !== sps; result.push(fixed.length >> 8, fixed.length & 255, ...fixed); }
    const tail = at; if (at >= avcC.length) return avcC;
    const ppsCount = avcC[at++]; if (!ppsCount) return avcC;
    for (let i = 0; i < ppsCount; i++) { const pps = take(); if ((pps[0] & 0x9f) !== 8 || !(pps[0] & 0x60)) return avcC; }
    return changed ? Uint8Array.from([...result, ...avcC.subarray(tail)]) : avcC;
  } catch { return avcC; }
}
