#!/usr/bin/env python3
"""Run real scripts against deterministic debugserver replies, not an iPhone."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
const original = ORIGINAL;
const corrected = CORRECTED;
let count = 0;
function assert(value, message) { if (!value) throw new Error(message); }
function hex(n) {
  let v = BigInt(n), s = '';
  for (let i=0; i<8; ++i) { s += Number(v & 255n).toString(16).padStart(2,'0'); v >>= 8n; }
  return s;
}
function scenario(source, options) {
  const calls = [], prepared = [], logs = [];
  const base = 0x7000000000n;
  let at = 0, reads = 0, threw = null;
  const normal = {pc:0x100000000n, kind:'normal', sig:'11', op:0n};
  const prepare = {pc:0x100000010n, kind:'prepare', sig:'05', op:1n};
  const detach = {pc:0x100000020n, kind:'detach', sig:'05', op:0n};
  const sequence = options.sequence || (options.interrupt ? [normal, prepare, detach] : [prepare, detach]);
  let stop = normal;
  function stopPacket(event) {
    if ('reply' in event) return event.reply;
    let regs = options.omitRegs ? '' : `20:${hex(event.pc)};10:${hex(event.op)};00:${hex(base + BigInt(event.offset || 0))};01:${hex(0x2000000n)};`;
    const thread = options.noThread ? '' : `thread:${options.thread || 'abc'};`;
    return `T${event.sig}` + (options.reorder ? 'metype:6;name:worker;' + regs + thread : thread + regs);
  }
  function send(command) {
    calls.push(command);
    if (++reads > 80) throw new Error('MOCK: unbounded resume after missing JIT stop');
    if (command.startsWith('vAttach;')) return 'T11thread:abc;';
    if (command === 'c' || command.startsWith('vCont;S')) {
      if (options.interrupt && at === 2 && prepared.length === 0)
        throw new Error('MOCK: target resumed past an unprepared JIT region');
      if (at >= sequence.length) throw new Error('MOCK: resumed after terminal event');
      stop = sequence[at++];
      return stopPacket(stop);
    }
    if (command === 'qC') return 'QC' + (options.thread || 'abc');
    if (command.startsWith('p20;')) return options.badRegister ? 'E45' : hex(stop.pc);
    if (command.startsWith('p10;')) return hex(stop.op);
    if (command.startsWith('p00;')) return hex(base + BigInt(stop.offset || 0));
    if (command.startsWith('p01;')) return hex(0x2000000n);
    if (command.startsWith('m')) {
      if (options.badInstruction) return 'E14';
      return stop.kind === 'normal' ? '1f2003d5' : (stop.kind === 'unknown' ? '200020d4' : 'a0013ed4');
    }
    if (command.startsWith('P20=')) return options.rejectPC ? 'E01' : 'OK';
    if (command.startsWith('P0=')) return options.rejectReturn ? 'E02' : 'OK';
    if (command === 'D') return options.rejectDetach ? 'E03' : 'OK';
    throw new Error('MOCK: unexpected command ' + command);
  }
  try {
    new Function('send_command', 'get_pid', 'prepare_memory_region', 'log', source)(
      send, () => 123,
      (address, length) => { prepared.push([address.toString(), length.toString()]); return options.rejectPrepare ? 'E09' : 'OK'; },
      (message) => logs.push(String(message)));
  } catch (error) { threw = String(error); }
  return {calls, prepared, threw, logs};
}
function test(name, action) { action(); ++count; }
test('negative control: baseline loses the reply returned by signal delivery', () => {
  const r = scenario(original, {interrupt:true});
  assert(r.prepared.length === 0, 'baseline should reproduce unprepared region');
  assert(r.threw && r.threw.includes('unprepared JIT'), 'baseline target resumes past BRK');
});
test('control: original direct preparation works', () => {
  const r = scenario(original, {});
  assert(!r.threw && r.prepared.length === 1, 'original ordinary path must work');
});
test('fixed: process stop returned by vCont BEFORE another resume', () => {
  const r = scenario(corrected, {interrupt:true});
  assert(!r.threw && r.prepared.length === 1, 'signal delivery must not lose JIT request');
  assert(r.calls.at(-1) === 'D', 'successful transaction detaches');
});
test('fixed: direct flow unchanged', () => {
  const r = scenario(corrected, {});
  assert(!r.threw && r.prepared[0][0] === String(0x7000000000n), 'full-width address retained');
});
test('multiple arena chunks', () => {
  const sequence = [0, 0x2000000, 0x4000000].map(offset => ({pc:0x100000010n,kind:'prepare',sig:'05',op:1n,offset}));
  sequence.push({pc:0x100000020n,kind:'detach',sig:'05',op:0n});
  const r = scenario(corrected, {sequence});
  assert(!r.threw && r.prepared.length === 3, 'all chunks prepared exactly once');
  assert(r.prepared[2][0] === String(0x7004000000n), 'chunk addresses are not truncated');
});
test('thread field need not be first', () => {
  const r = scenario(corrected, {reorder:true});
  assert(!r.threw && r.prepared.length === 1, 'field order is not fixed');
});
test('missing registers fetched from the stopped thread', () => {
  const r = scenario(corrected, {omitRegs:true});
  assert(!r.threw && r.prepared.length === 1 && r.calls.includes('p20;thread:abc;'), 'fallback reads required');
});
test('missing thread falls back to qC', () => {
  const r = scenario(corrected, {noThread:true});
  assert(!r.threw && r.calls.includes('qC'), 'qC fallback');
});
test('multiprocess thread IDs', () => {
  const r = scenario(corrected, {thread:'p7b.abc', omitRegs:true});
  assert(!r.threw && r.calls.includes('p20;thread:p7b.abc;'), 'multiprocess thread preserved');
});
test('single step SIGTRAP is not injected into the target', () => {
  const r = scenario(corrected, {sequence:[
    {pc:0x100000000n,kind:'normal',sig:'11',op:0n},
    {pc:0x100000004n,kind:'normal',sig:'05',op:0n},
    {pc:0x100000010n,kind:'prepare',sig:'05',op:1n},
    {pc:0x100000020n,kind:'detach',sig:'05',op:0n}]});
  assert(!r.threw && r.prepared.length === 1, 'continue after step completion');
  assert(!r.calls.some(c => c.startsWith('vCont;S05')), 'do not inject debugger SIGTRAP');
});
for (const reply of ['W00', 'X09', 'E22', '', 'OK']) test('terminal/malformed ' + reply, () => {
  const r = scenario(corrected, {sequence:[{reply}]});
  assert(r.threw && r.threw.includes('invalid/terminal stop'), 'reject instead of infinite continue');
  assert(r.calls.filter(c=>c==='c').length === 1, 'no second resume after termination');
});
for (const field of ['rejectPC', 'rejectReturn', 'badInstruction', 'badRegister', 'rejectDetach']) test(field, () => {
  const r = scenario(corrected, {[field]:true, omitRegs:field==='badRegister'});
  assert(r.threw && r.threw.includes('NEOSTATION_RPCS3_STOP_REPLY_270'), 'invalid debugger reply must fail');
});
test('preparation refusal returns zero, never the unprepared address', () => {
  const r = scenario(corrected, {rejectPrepare:true});
  assert(r.calls.includes('P0=0000000000000000;thread:abc;'), 'core receives failure');
  assert(!r.calls.includes('P0=' + hex(0x7000000000n) + ';thread:abc;'), 'no false success');
});
test('unknown breakpoint not silently skipped', () => {
  const r = scenario(corrected, {sequence:[{pc:0x100000000n,kind:'unknown',sig:'05',op:0n}]});
  assert(r.threw && r.threw.includes('unsupported BRK'), 'unknown BRK is a protocol failure');
});
globalThis.RESULT_270 = 'PASS: Build 270 protocol: ' + count + ' executable scenarios including baseline negative control';
'''


def main():
    source = Path(sys.argv[1])
    original = (source / 'Resources/universal.js').read_text()
    fixed = (source / 'Resources/rpcs3-universal.js').read_text()
    before = hashlib.sha256(original.encode()).hexdigest()
    subprocess.run(['python3', str(ROOT / 'build-utils/patch_rpcs3_stop_reply270.py'), '--stik-source', str(source)], check=True)
    assert before == hashlib.sha256((source / 'Resources/universal.js').read_bytes()).hexdigest()
    assert fixed == (source / 'Resources/rpcs3-universal.js').read_text(), 'idempotent custom generation'
    harness = HARNESS.replace('ORIGINAL', json.dumps(original)).replace('CORRECTED', json.dumps(fixed))
    result = subprocess.run(['node', '-e', harness + '\nconsole.log(RESULT_270);'], capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    print('Node: ' + result.stdout.strip())
    if sys.platform == 'darwin':
        with tempfile.TemporaryDirectory(prefix='rpcs3-jsc270-') as temp:
            temp = Path(temp)
            (temp / 'test.js').write_text(harness)
            (temp / 'test.swift').write_text('''import Foundation
import JavaScriptCore
let context = JSContext()!
var error: String?
context.exceptionHandler = { _, value in error = value?.toString() ?? "JavaScript exception" }
context.evaluateScript(try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8))
if let error { fputs(error + "\\n", stderr); exit(1) }
guard let result = context.objectForKeyedSubscript("RESULT_270")?.toString(), result.hasPrefix("PASS:") else { exit(2) }
print("JavaScriptCore: " + result)
''')
            subprocess.run(['swift', str(temp / 'test.swift'), str(temp / 'test.js')], check=True, timeout=45)


if __name__ == '__main__':
    main()
