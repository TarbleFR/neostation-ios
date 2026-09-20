// Universal JIT Script, last updated 2026-29-03 (YYYY-DD-MM)
/*
 // JIT "syscalls"
 __attribute__((noinline,optnone,naked))
 void JIT26Detach(void) {
     asm("mov x16, #0 \n"
         "brk #0xf00d \n"
         "ret");
 }
 __attribute__((noinline,optnone,naked))
 void* JIT26PrepareRegion(void *addr, size_t len) {
     asm("mov x16, #1 \n"
         "brk #0xf00d \n"
         "ret");
 }

 __attribute__((noinline,optnone,naked))
void BreakSendJITScript(char* script, size_t len) {
    asm("mov x16, #2 \n"
        "brk #0xf00d \n"
        "ret");
}
 */
const CMD_DETACH = 0;
const CMD_PREPARE_REGION = 1;
const CMD_NEW_BREAKPOINTS = 2;
const NEOSTATION_STIKJIT_UNIVERSAL_V1 = "NEOSTATION_STIKJIT_UNIVERSAL_V1";
const commands = {
    [CMD_DETACH]: JIT26Detach,
    [CMD_PREPARE_REGION]: JIT26PrepareRegion,
    [CMD_NEW_BREAKPOINTS]: JIT26NewBreakpoints,
    [3]: NeoStationDebuggerProbe
};
const legacyCommands = {
    [0x68]: JIT26NewBreakpoints,
    [0x69]: JIT26HandleBrk0x69,
    [0xf00d]: JIT26HandleBrk0xf00d
};

// Log levels
//const LOG_NONE = 0;
const LOG_INFO = 1;
const LOG_VERBOSE = 2;
let logLevel = LOG_INFO;
function log_verbose(msg) {
    if (logLevel >= LOG_VERBOSE) {
        log(msg);
    }
}

// To avoid having to re-parse these in each function, we save some registers here
let tid, x0, x1, x16, pc;
let detached = false;
let pendingStopReply = null;
let lastForeignStopKey = null;
let repeatedForeignStops = 0;
let pid = get_pid();
let attachResponse = send_command(`vAttach;${pid.toString(16)}`);

// A stop reply and a process-info reply are independent checks. Never publish
// attachment from a diagnostic string or from the persistent CS_DEBUGGED bit.
if (!/^[TS][0-9a-fA-F]{2}/.test(attachResponse)) {
    throw new Error(`vAttach did not return a stop reply: ${attachResponse}`);
}
const processInfo = send_command("qProcessInfo");
const processMatch = /(?:^|;)pid:([0-9a-fA-F]+);/.exec(processInfo);
if (!processMatch || parseInt(processMatch[1], 16) !== pid) {
    send_command("D");
    throw new Error("debugserver process identity does not match the requested PID");
}
log(`NEOSTATION_DEBUGGER_ATTACHED_V1 pid=${pid} nonce=${neostationProbeNonce}`);
    
let totalBreakpoints = 0;
try {
while (!detached) {
    totalBreakpoints++;
    log(`Handling signal ${totalBreakpoints}`);
    
    // A resume command returns the NEXT stop, not an acknowledgement. Consume
    // it once before issuing any other resume (including signal delivery).
    const brkResponse = pendingStopReply === null ? send_command(`c`) : pendingStopReply;
    pendingStopReply = null;
    log(`RPCS3_RSP_STOP pid=${pid} sequence=${totalBreakpoints} reply=${String(brkResponse).slice(0, 1536)}`);
    if (typeof brkResponse !== 'string' || !/^[TS][0-9a-fA-F]{2}/.test(brkResponse))
        throw new Error(`RPCS3 target exited or returned an invalid stop: ${String(brkResponse).slice(0, 256)}`);
    
    // Expedited register fields are optional; their ordering is not fixed.
    tid = stoppedThread(brkResponse);
    pc = stoppedRegister(brkResponse, '20', tid);
    const signal = brkResponse.slice(1, 3);

    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    log(`instruction at pc: ${instructionResponse}`);
    let instrU32 = littleEndianHexToU32(instructionResponse);
    
    // check if this is a brk
    if ((instrU32 & 0xFFE0001F)>>>0 != 0xD4200000) {
        log(`Skipping: instruction was not a brk (was 0x${instrU32.toString(16)})`);
        // Build 298 device evidence shows T06 is a real Core SIGABRT when the
        // low-VA arena reservation fails before the first command-1 request.
        // Suppressing that signal only drives libc's abort path into a repeated
        // BRK stop. Preserve real target signals and consume the returned stop
        // exactly once; the fixed Core should no longer generate this abort.
        guardForeignStop(signal, tid, pc, instrU32);
        log(`RPCS3_FOREIGN_STOP_FORWARDED pid=${pid} signal=${signal} thread=${tid}`);
        pendingStopReply = send_command(`vCont;C${signal}:${tid};c`);
        continue;
    }
    
    let brkImmediate = extractBrkImmediate(instrU32);
    log(`BRK immediate: 0x${brkImmediate.toString(16)} (${brkImmediate})`);
    if (legacyCommands[brkImmediate] != undefined) {
        x16 = stoppedRegister(brkResponse, '10', tid);
        x0 = stoppedRegister(brkResponse, '00', tid);
        x1 = stoppedRegister(brkResponse, '01', tid);
        if (brkImmediate === 0xf00d && commands[x16] === undefined)
            throw new Error(`Unknown RPCS3 JIT command ${x16.toString(16)}`);

        // jump over brk
        let pcPlus4 = numberToLittleEndianHexString(pc + 4n);
        let pcPlus4Response = send_command(`P20=${pcPlus4};thread:${tid};`);
        if (pcPlus4Response !== "OK") {
            send_command("D");
            throw new Error("debugserver rejected the breakpoint PC advance");
        }
        log(`pcPlus4Response = ${pcPlus4Response}`);

        // dispatch brk-immediate command
        const command = legacyCommands[brkImmediate];
        command(brkResponse);
    } else {
        // A foreign breakpoint is not a JIT call. Preserve its signal and PC,
        // but refuse to spin forever if an abort/trap path returns to the same
        // instruction repeatedly (Build 298 observed >4,000 identical BRK #1 stops).
        guardForeignStop(signal, tid, pc, instrU32);
        log(`RPCS3_FOREIGN_BRK_FORWARDED pid=${pid} signal=${signal} thread=${tid} immediate=0x${brkImmediate.toString(16)}`);
        pendingStopReply = send_command(`vCont;C${signal}:${tid};c`);
        continue;
    }
}
} catch (error) {
    log(`RPCS3_PROTOCOL_ERROR pid=${pid}: ${String(error)}`);
    throw error;
}

// A host-owned BRK #0xf00d / command 3 makes a real round trip through
// debugserver before dlopen. The nonce response is visible to the host only
// after the *next* continue resumes its probe thread. No timer can satisfy it.
function NeoStationDebuggerProbe() {
    if (x0 !== BigInt(neostationProbeNonce)) {
        send_command("D");
        throw new Error("debugger probe nonce mismatch");
    }
    const reply = send_command(`P0=${numberToLittleEndianHexString(x0 + 1n)};thread:${tid};`);
    if (reply !== "OK") {
        send_command("D");
        throw new Error("debugserver rejected the probe response");
    }
    log(`NEOSTATION_DEBUGGER_PROBE_V1 pid=${pid} nonce=${neostationProbeNonce}`);
}

function JIT26Detach() {
    let detachResponse = send_command(`D`);
    requireOK(detachResponse, 'detach');
    log_verbose(`detachResponse = ${detachResponse}`);
    detached = true;
}

// brk 0x68
function JIT26NewBreakpoints(brkResponse) {
    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    log(`instruction at pc: ${instructionResponse}`);
    let instrU32 = littleEndianHexToU32(instructionResponse);
    let brkImmediate = extractBrkImmediate(instrU32);
    
    let memResponse = send_command(`m${x0.toString(16)},${x1}`);

    let scriptText = hexToAscii(memResponse);
    log_verbose(`Script text: ${scriptText}`);

    const res = runScriptAndCapture(scriptText);
    if (res.ok) {
        log('Script succeeded:', res.value);
    } else {
        log('Script failed:', res.name, res.message);
        log(res.stack);
    }
}

// brk 0x69
function JIT26HandleBrk0x69(brkResponse) {
    // in the old script we chose 0x69, so now we check here and return error
    // if you wish to keep using this, you can set your own handler like `legacyCommands[0x69] = yourHandler;` using BreakSendJITScript
    log(`Error: It seems you are using legacy breakpoint 0x69. Please set your legacy handler using \`legacyCommands[0x69] = yourHandler;\` or migrate to universal jitcalls to use this script. The function will now return 0xE0000069.`);
    let putX0Response = send_command(`P0=E0000069;thread:${tid};`);
    log(`putX0Response = ${putX0Response}`);
}

// brk 0xf00d
function JIT26HandleBrk0xf00d(brkResponse) {
    // dispatch command via x16
    const command = commands[x16];
    if (command === undefined) {
        log(`Unknown command ${x16.toString(16)}`);
        return;
    }
    log(`Invoking command ${x16.toString(16)}`);
    command(brkResponse);
}

function JIT26PrepareRegion(brkResponse) {
    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    log(`instruction at pc: ${instructionResponse}`);
    let instrU32 = littleEndianHexToU32(instructionResponse);
    let brkImmediate = extractBrkImmediate(instrU32);
    
    if (x0 == 0n && x1 == 0n) {
        return;
    }

    let jitPageAddress = x0;
    if (x0 == 0n) {
        let requestRXResponse = send_command(`_M${x1.toString(16)},rx`);
        log_verbose(`requestRXResponse = ${requestRXResponse}`);
        
        if (!requestRXResponse || requestRXResponse.length === 0) {
            log(`Failed to allocate RX memory`);
            return;
        }
        
        jitPageAddress = BigInt(`0x${requestRXResponse}`);
        log(`Allocated JIT page at address: 0x${jitPageAddress.toString(16)}`);
    }

    log(`NEOSTATION_RPCS3_PREPARE_BEGIN addr=0x${jitPageAddress.toString(16)} len=${x1.toString()}`);
    let prepareJITPageResponse = prepare_memory_region(jitPageAddress, x1);
    log(`prepareJITPageResponse = ${prepareJITPageResponse}`);
    log(`NEOSTATION_RPCS3_PREPARE_END addr=0x${jitPageAddress.toString(16)} len=${x1.toString()} result=${prepareJITPageResponse}`);
    if (prepareJITPageResponse !== "OK") {
        log(`NEOSTATION_STIKJIT_UNIVERSAL_V1: debugserver page preparation failed; returning zero to the target`);
        let putFailureX0Response = send_command(`P0=${numberToLittleEndianHexString(0n)};thread:${tid};`);
        requireOK(putFailureX0Response, 'preparation failure return');
        log(`putFailureX0Response = ${putFailureX0Response}`);
        return;
    }

    let putX0Response = send_command(`P0=${numberToLittleEndianHexString(jitPageAddress)};thread:${tid};`);
    requireOK(putX0Response, 'prepared address return');
    log(`putX0Response = ${putX0Response}`);
}

// utilities
function littleEndianHexStringToNumber(hexStr) {
    const bytes = [];
    for (let i = 0; i < hexStr.length; i += 2) {
        bytes.push(parseInt(hexStr.substr(i, 2), 16));
    }
    let num = 0n;
    for (let i = 7; i >= 0; i--) {
        num = (num << 8n) | BigInt(bytes[i]);
    }
    return num;
}

function numberToLittleEndianHexString(num) {
    const bytes = [];
    for (let i = 0; i < 8; i++) {
        bytes.push(Number(num & 0xFFn));
        num >>= 8n;
    }
    while (bytes.length < 8) {
        bytes.push(0);
    }
    return bytes.map(b => b.toString(16).padStart(2, '0')).join('');
}

function littleEndianHexToU32(hexStr) {
    if (typeof hexStr !== 'string' || !/^[0-9a-fA-F]{8}$/.test(hexStr))
        throw new Error(`Cannot read RPCS3 stopped instruction: ${String(hexStr)}`);
    return parseInt(hexStr.match(/../g).reverse().join(''), 16);
}

function extractBrkImmediate(u32) {
    return (u32 >> 5) & 0xFFFF;
}

function hexToAscii(hexStr) {
    let str = '';
    for (let i = 0; i < hexStr.length; i += 2) {
        const byte = parseInt(hexStr.substr(i, 2), 16);
        if (byte === 0) break;
        str += String.fromCharCode(byte);
    }
    return str;
}

function runScriptAndCapture(scriptText) {
    try {
        const value = eval(scriptText);
        return { ok: true, value };
    } catch (err) {
        return {
            ok: false,
            name: err && err.name,
            message: err && err.message,
            stack: err && err.stack
        };
    }
}

// For making your own script / adding your own breakpoints. you can send this string to BreakSendJITScript and it'll add it for any subsequent breakpoints
// x0, x1, x16, pc and tid are global variables. If you need more registers, parse them like:
// tmpMatch = /02:(?<reg>[0-9a-f]{16});/.exec(brkResponse); // x2
// let x2 = tmpMatch ? tmpMatch.groups['reg'] : null;
// if (!x2) {
//     log(`Failed to extract registers: x2=${x2}`);
//     return;
// }
// x2 = littleEndianHexStringToNumber(x2);
//
/*
commands[3] = wowBreakPoint;

function wowBreakPoint(brekpoint) {
    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    log(`instruction at pc: ${instructionResponse}`);
    let instrU32 = littleEndianHexToU32(instructionResponse);
    let brkImmediate = extractBrkImmediate(instrU32);
    
    if (x0 == 0n && x1 == 0n) {
        return;
    }

    let jitPageAddress = x0;
    let prepareJITPageResponse = prepare_memory_region(jitPageAddress, x1);
    log(`prepareJITPageResponse = ${prepareJITPageResponse}`);

    let putX0Response = send_command(`P0=${numberToLittleEndianHexString(jitPageAddress)};thread:${tid};`);
    log(`putX0Response = ${putX0Response}`);
}
*/

// GDB remote all-stop packet fields may appear in any order. Reading a missing
// register does not resume the target. The common full-reply path needs no
// additional network command.
function stoppedThread(reply) {
    const fields = reply.slice(3).split(';');
    const field = fields.find(value => value.startsWith('thread:'));
    let thread = field ? field.slice(7) : null;
    if (thread === null) {
        const current = /^QC(.+)$/.exec(String(send_command('qC')));
        if (!current) throw new Error('Cannot query RPCS3 stopped thread');
        thread = current[1];
    }
    if (!/^(?:[0-9a-fA-F]+|p[0-9a-fA-F]+\.[0-9a-fA-F]+)$/.test(thread))
        throw new Error('Cannot identify RPCS3 stopped thread');
    return thread;
}
function stoppedRegister(reply, index, thread) {
    const wanted = parseInt(index, 16);
    const field = reply.slice(3).split(';').find(value => {
        const key = value.split(':', 1)[0];
        return /^[0-9a-fA-F]+$/.test(key) && parseInt(key, 16) === wanted;
    });
    const value = field ? field.slice(field.indexOf(':') + 1) :
        send_command(`p${index};thread:${thread};`);
    if (typeof value !== 'string' || !/^[0-9a-fA-F]{16}$/.test(value))
        throw new Error(`Cannot read RPCS3 register ${index}`);
    return littleEndianHexStringToNumber(value);
}
function guardForeignStop(signal, thread, address, instruction) {
    const key = `${signal}:${thread}:${address.toString(16)}:${instruction.toString(16)}`;
    if (key === lastForeignStopKey) repeatedForeignStops++;
    else {
        lastForeignStopKey = key;
        repeatedForeignStops = 1;
    }
    if (repeatedForeignStops <= 8) return;
    const detachResponse = send_command('D');
    log(`RPCS3_FOREIGN_STOP_LOOP_GUARD pid=${pid} repeats=${repeatedForeignStops} detach=${String(detachResponse)}`);
    throw new Error(`RPCS3 repeated the same foreign debugger stop ${repeatedForeignStops} times; refusing an infinite bootstrap loop`);
}

function requireOK(reply, operation) {
    if (reply !== 'OK') throw new Error(`RPCS3 ${operation} rejected: ${String(reply).slice(0, 128)}`);
}