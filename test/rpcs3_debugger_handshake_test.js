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
console.log('PASS: real script attach/PID/nonce/PC/register acknowledgement/resume and five rejection paths');
