// Replays all-stop debugserver replies against the actual shipping JS. This is
// a protocol test, NOT a reproduction of a hardware-only iOS crash.
const fs = require('fs');
const vm = require('vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(process.argv[2] || 'packages/rpcs3_jit_helper/ios/Resources/rpcs3-universal.js', 'utf8');
const hex = n => { const b = Buffer.alloc(8); b.writeBigUInt64LE(BigInt(n)); return b.toString('hex'); };
function run({reordered=false, sparse=false, signal=false, terminal=false, ack='OK'}={}) {
  let stage='probe', advanced=false, prepared=0, unhandledResumes=0, forwarded=0, suppressed=0;
  const commands=[], logs=[];
  const pc=()=>stage==='signal'?0x3000:0x1000;
  const reg=k=>({20:hex(pc()), 10:hex(stage==='probe'?3:stage==='jit'?1:0),
    '00':hex(stage==='probe'?42:stage==='jit'?0x14c000000:0), '01':hex(stage==='jit'?16777216:0)})[k];
  const stop=()=> {
    const sig=stage==='signal'?'06':'05';
    let fields=(stage==='jit'&&reordered)?'metype:6;mecount:2;thread:1;':'thread:1;';
    if (!(stage==='jit'&&sparse)) fields+=['20','10','00','01'].map(k=>`${k}:${reg(k)};`).join('');
    return `T${sig}${fields}`;
  };
  let first=true;
  const sandbox={neostationProbeNonce:42, get_pid:()=>123, log:v=>logs.push(v),
    prepare_memory_region:(address,length)=> {
      assert.equal(address,0x14c000000n); assert.equal(length,16777216n); prepared++; return 'OK';
    }, send_command:command=> {
      commands.push(command); if(commands.length>100) throw Error('Repeated unhandled stop');
      if(command.startsWith('vAttach;')) return 'T11thread:1;';
      if(command==='qProcessInfo') return 'pid:7b;';
      if(command==='qC') return 'QC1';
      if(command.startsWith('p')) return reg(command.split(';')[0].slice(1));
      if(command==='c') {
        if(first){first=false;return stop();}
        if(advanced){
          advanced=false;
          stage=stage==='probe'?(signal?'signal':terminal?'exit':'jit'):'detach';
        } else if(stage==='signal') {
          // Device Build 294 failure: T06 must be consumed without re-delivery.
          suppressed++;
          stage='jit';
        } else {
          unhandledResumes++;
        }
        return stage==='exit'?'W09':stop();
      }
      if(command.startsWith('vCont;')) {
        forwarded++; stage='jit'; advanced=false; return stop();
      }
      if(command.startsWith('m')) return stage==='signal'?'1f2003d5':'a0013ed4';
      if(command.startsWith('P20=')){advanced=true;return 'OK';}
      if(command.startsWith('P0=')) return stage==='jit'?ack:'OK';
      if(command==='D') return 'OK';
      throw Error(`Unexpected command ${command}`);
    }};
  let error;
  try{vm.runInNewContext(source,sandbox,{timeout:1000});}catch(e){error=e;}
  return {error,prepared,unhandledResumes,forwarded,suppressed,commands,logs};
}
const failures=[];
for(const [name,options] of Object.entries({normal:{},reordered:{reordered:true},sparse:{sparse:true},signal:{signal:true}})) {
  const result=run(options);
  try {
    assert.equal(result.error,undefined); assert.equal(result.prepared,1);
    assert.equal(result.unhandledResumes,0,'a stop reply must be consumed before resuming');
    if(options.signal) {
      assert.equal(result.suppressed,1,'T06 must be suppressed exactly once');
      assert.equal(result.commands.some(c=>c.startsWith('vCont;C06')),false,
        're-delivering signal 6 reproduces the device X06 termination');
      assert.ok(result.logs.some(v=>v.includes('RPCS3_FOREIGN_STOP_SUPPRESSED')));
    }
    if(!options.sparse) assert.equal(result.commands.filter(c=>c.startsWith('p')||c==='qC').length,0,'no extra register round trips on normal packets');
    console.log(`PASS: ${name}`);
  }catch(e){failures.push(`${name}: ${e.message}`);}
}
const terminal=run({terminal:true});
if(!terminal.error||terminal.commands.length>20) failures.push('terminal exit was not reported immediately');
const refused=run({ack:'E03'});
if(!refused.error) failures.push('failed return-register write accepted');
if(failures.length){console.error(failures.join('\n'));process.exit(1);}
console.log('PASS: terminal exit and failed write cannot become JIT success');
