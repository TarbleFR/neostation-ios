// Executes the actual bundled production script against a deterministic
// debugserver. A delay/log line alone cannot make any case succeed.
const fs = require('fs');
const vm = require('vm');
const assert = require('node:assert/strict');
const script = fs.readFileSync('packages/rpcs3_jit_helper/ios/Resources/rpcs3-universal.js', 'utf8');
const hex = n => { const b = Buffer.alloc(8); b.writeBigUInt64LE(BigInt(n)); return b.toString('hex'); };
function run({pid = 123, attach = 'T11thread:1;', nonce = 42, pcReply = 'OK', probeReply = 'OK'} = {}) {
  const log = [], commands = [];
  let continues = 0, probeWritten = false, resumed = false;
  const stop = command => `T05thread:1;20:${hex(0x1000)};10:${hex(command)};00:${hex(nonce)};01:${hex(0)};`;
  const sandbox = {
    neostationProbeNonce: 42, get_pid: () => 123,
    log: value => log.push(value), prepare_memory_region: () => 'OK',
    send_command: command => {
      commands.push(command);
      if (command.startsWith('vAttach;')) return attach;
      if (command === 'qProcessInfo') return `pid:${pid.toString(16)};parent-pid:1;`;
      if (command === 'c') {
        if (++continues === 1) return stop(3);
        resumed = probeWritten;
        return stop(0);
      }
      if (command === 'm1000,4' || command === 'm1004,4') return 'a0013ed4';
      if (command.startsWith('P20=')) return pcReply;
      if (command.startsWith('P0=')) { probeWritten = command === `P0=${hex(43)};thread:1;` && probeReply === 'OK'; return probeReply; }
      if (command === 'D') return 'OK';
      throw Error(`Unexpected command ${command}`);
    },
  };
  let error;
  try { vm.runInNewContext(script, sandbox, {timeout: 500}); } catch (e) { error = e; }
  return {error, log, commands, resumed};
}
const ok = run();
assert.equal(ok.error, undefined);
assert.equal(ok.resumed, true);
assert.equal(ok.commands[0], 'vAttach;7b');
assert.ok(ok.log.includes('NEOSTATION_DEBUGGER_ATTACHED_V1 pid=123 nonce=42'));
for (const options of [{pid: 999}, {attach: 'E01'}, {nonce: 41}, {pcReply: 'E02'}, {probeReply: 'E03'}]) {
  const failed = run(options);
  assert.ok(failed.error, JSON.stringify(options));
  assert.equal(failed.resumed, false, JSON.stringify(options));
}
assert.equal(run({pid: 999}).log.some(v => v.startsWith('NEOSTATION_DEBUGGER_ATTACHED')), false);

// Build 298 evidence corrected the Build 294 interpretation: T06 is a real
// SIGABRT from the Core when low-VA arena reservation fails. A foreign signal
// must be forwarded and its synchronous next-stop reply consumed exactly once.
// Suppressing SIGABRT only turns the abort path into a repeated BRK loop.
function runForeignStop() {
  const commands = [], log = [];
  let cCount = 0;
  const stop = (signal, pc, command) =>
    `T${signal}thread:1;20:${hex(pc)};10:${hex(command)};00:${hex(42)};01:${hex(0)};`;
  const sandbox = {
    neostationProbeNonce: 42,
    get_pid: () => 123,
    log: value => log.push(value),
    prepare_memory_region: () => 'OK',
    send_command: command => {
      commands.push(command);
      if (command.startsWith('vAttach;')) return 'T11thread:1;';
      if (command === 'qProcessInfo') return 'pid:7b;parent-pid:1;';
      if (command === 'c') {
        cCount++;
        if (cCount === 1) return stop('05', 0x1000, 3); // nonce probe
        if (cCount === 2) return stop('0b', 0x2000, 0); // application signal
        throw Error('RPCS3 issued an unexpected plain continue');
      }
      if (command === 'vCont;C0b:1;c') return stop('05', 0x1000, 0); // forwarded signal -> detach BRK
      if (command === 'm1000,4') return 'a0013ed4';
      if (command === 'm2000,4') return '1f2003d5'; // AArch64 NOP
      if (command.startsWith('P20=')) return 'OK';
      if (command.startsWith('P0=')) return 'OK';
      if (command === 'D') return 'OK';
      throw Error(`Unexpected command ${command}`);
    },
  };
  let error;
  try { vm.runInNewContext(script, sandbox, {timeout: 500}); } catch (e) { error = e; }
  return {error, commands, log, cCount};
}
const foreign = runForeignStop();
assert.equal(foreign.error, undefined);
assert.equal(foreign.commands.some(value => value === 'vCont;C0b:1;c'), true);
assert.equal(foreign.commands.some(value => value.startsWith('vCont;S')), false);
assert.ok(foreign.log.some(value => value.includes('RPCS3_FOREIGN_STOP_FORWARDED')));
assert.equal(foreign.cCount, 2);
assert.ok(foreign.log.some(value => value.includes('RPCS3_RSP_STOP')));
// Exact Build 298 fatal path: forwarding SIGABRT must terminate promptly,
// never suppress it into thousands of repeated BRK stops.
function runAbortStop() {
  const commands = [], log = [];
  let cCount = 0;
  const sandbox = {
    neostationProbeNonce: 42, get_pid: () => 123,
    log: value => log.push(value), prepare_memory_region: () => 'OK',
    send_command: command => {
      commands.push(command);
      if (commands.length > 20) throw Error('unbounded abort loop');
      if (command.startsWith('vAttach;')) return 'T11thread:1;';
      if (command === 'qProcessInfo') return 'pid:7b;parent-pid:1;';
      if (command === 'c') {
        cCount++;
        if (cCount === 1) return stopPacket('05', 0x1000, 3);
        if (cCount === 2) return stopPacket('06', 0x2000, 0);
      }
      if (command === 'vCont;C06:1;c') return 'X06';
      if (command === 'm1000,4') return 'a0013ed4';
      if (command === 'm2000,4') return '03010054';
      if (command.startsWith('P20=')) return 'OK';
      if (command.startsWith('P0=')) return 'OK';
      if (command === 'D') return 'OK';
      throw Error(`Unexpected command ${command}`);
    },
  };
  function stopPacket(signal, pc, command) {
    return `T${signal}thread:1;20:${hex(pc)};10:${hex(command)};00:${hex(42)};01:${hex(0)};`;
  }
  let error;
  try { vm.runInNewContext(script, sandbox, {timeout: 500}); } catch (e) { error = e; }
  return {error, commands, log};
}
const abortStop = runAbortStop();
assert.ok(abortStop.error);
assert.equal(abortStop.commands.filter(value => value === 'vCont;C06:1;c').length, 1);
assert.ok(abortStop.log.some(value => value.includes('RPCS3_FOREIGN_STOP_FORWARDED')));
assert.ok(abortStop.commands.length < 20);
console.log('PASS: RPCS3 consumes each debugger stop exactly once, forwards real target signals, and bounds fatal loops');
console.log('PASS: real script attach/PID/nonce/PC/register acknowledgement/resume and five rejection paths');