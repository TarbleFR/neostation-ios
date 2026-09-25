#!/usr/bin/env python3
"""Checked frame-boundary/return bridge for the pinned RMCP01 iOS donor.

RKSystem::run is an endless translated function. At the end of its frame it
has no live nested guest calls: x19 points to the materialized CpuContext.
A host gate may update guest language state or ask run to return normally.
The return path restores run's exact native callee-save frame; the host entry
wrapper restores the guest caller context, so RKSystem::main can unwind into
RuntimeMain's existing fiber/Aurora cleanup. The startup call to guest exit
is routed through an explicit host guard, so only a successfully drained
embedded session returns instead of terminating NeoStation. No exit, longjmp, cancellation,
in-process instruction writes, JIT, or UIKit work on an arbitrary guest stack.

Unused __TEXT load-command padding holds RX trampolines. Unclaimed zero-fill
__DATA tail holds two host function pointers. Every byte/range is verified;
we reject a changed donor rather than applying offsets to another binary.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import struct
from patch_donor_language_bridge import parse_macho, load_symbols, vm_to_file, encode_adrp, validate_bridge

BASE = 0x100000000
RUN = 0x101A9DE84
RUN_SIZE = 3484
FRAME = 0x101A9E8C4  # after RKSystem::onEndFrame returns; CpuContext in x19
TRAMPOLINE = BASE + 0x8000
GATE = BASE + 0x8040
CONTROL = 0x10534FF80
EXIT_GATE = BASE + 0x8D00
EXIT_CALL = 0x1002EC3EC
EXIT_ORIGINAL = 0x1002EC9D8
ENTRY = 0x1002ebec4
ENTRY_SIZE = 1584
EXPECTED_ENTRY_SHA = '47c297f928e428b89922a7cdaa0a5d4a7086820d0cf6583a8c8dd6d28198dcd1'
MAGIC = b'NEOKARTPAD-FRAME-RETURN-v1\0'
MAGIC_VM = BASE + 0x8F00
EXPECTED_RUN_SHA = '5a52a9da9e56a0b71691bb2eeff9c5685f2f3982f697f1538a43dc63a98f48e6'
PROLOGUE = bytes.fromhex('ff0303d1fc6f06a9fa6707a9f85f08a9')
FRAME_INSTRUCTION = 0x29424666  # ldp w6, w17, [x19, #0x10]


def branch(pc, target, opcode=0x14000000):
    delta = target - pc
    if delta % 4 or not -(1 << 27) <= delta < 1 << 27:
        raise SystemExit('ERROR: session bridge branch out of range')
    return opcode | ((delta // 4) & 0x3ffffff)


def pair(load, vector, r1, r2, offset):
    unit = 16 if vector else 8
    if offset % unit or not 0 <= offset // unit < 64:
        raise SystemExit('ERROR: invalid session bridge stack pair')
    op = (0xAD400000 if load else 0xAD000000) if vector else (0xA9400000 if load else 0xA9000000)
    return op | ((offset // unit) << 15) | (r2 << 10) | (31 << 5) | r1


def ldr_x(rt, rn, offset):
    if offset % 8 or not 0 <= offset // 8 < 4096:
        raise SystemExit('ERROR: invalid session control pointer offset')
    return 0xF9400000 | ((offset // 8) << 10) | (rn << 5) | rt


def words(items):
    return struct.pack('<' + 'I' * len(items), *items)


def gate_bytes():
    # Keep all GPRs, SIMD registers, SP and NZCV unchanged on continuation.
    code = [0xD10C43FF]  # sub sp, sp, #0x310 (16-byte aligned)
    for reg in range(0, 30, 2):
        code.append(pair(False, False, reg, reg + 1, reg * 8))
    code += [0xF9007BFE, 0xD53B4210, 0xF9007FF0]  # x30, NZCV at f0/f8
    for reg in range(0, 32, 2):
        code.append(pair(False, True, reg, reg + 1, 0x100 + reg * 16))
    code.extend([0xD53B4410, 0xF90183F0, 0xD53B4430, 0xF90187F0])  # FPCR/FPSR
    code.append(0xAA1303E0)  # mov x0, x19
    code.append(encode_adrp(16, GATE + len(code) * 4, CONTROL))
    code.append(ldr_x(16, 16, (CONTROL & 0xfff) + 8))
    code.append(0xD63F0200)  # blr x16 -> host frame boundary
    test = len(code)
    code.append(0)  # cbnz w0, quit_restore

    def restore():
        for reg in range(0, 32, 2):
            code.append(pair(True, True, reg, reg + 1, 0x100 + reg * 16))
        code.extend([0xF94183F0, 0xD51B4410, 0xF94187F0, 0xD51B4430])
        code.extend([0xF9407FF0, 0xD51B4210, 0xF9407BFE])
        for reg in range(0, 30, 2):
            code.append(pair(True, False, reg, reg + 1, reg * 8))
        code.append(0x910C43FF)  # add sp, sp, #0x310

    restore()
    code.append(FRAME_INSTRUCTION)
    code.append(branch(GATE + len(code) * 4, FRAME + 4))
    quit_index = len(code)
    restore()
    # RKSystem::run's own 0xc0-byte native stack, verified by its source hash.
    for r1, r2, off in ((28,27,0x60),(26,25,0x70),(24,23,0x80),
                       (22,21,0x90),(20,19,0xA0),(29,30,0xB0)):
        code.append(pair(True, False, r1, r2, off))
    code += [0x910303FF, 0xD65F03C0]  # add sp, #c0; ret (normal return)
    code[test] = 0x35000000 | (((quit_index - test) & 0x7ffff) << 5)
    return words(code)


def expected_patches():
    entry = words([encode_adrp(16, RUN, CONTROL),
                   ldr_x(16,16,CONTROL & 0xfff),0xD61F0200,0xD503201F])
    trampoline = PROLOGUE + words([branch(TRAMPOLINE+16,RUN+16)])
    return {RUN:entry, FRAME:words([branch(FRAME,GATE)]),
            TRAMPOLINE:trampoline, GATE:gate_bytes(), MAGIC_VM:MAGIC,
            EXIT_CALL:words([branch(EXIT_CALL,EXIT_GATE,0x94000000)]),
            EXIT_GATE:words([encode_adrp(16,EXIT_GATE,CONTROL),
                             ldr_x(16,16,(CONTROL & 0xfff)+16),0xD61F0200])}


def layout(data):
    segments, table = parse_macho(data)
    symbols, _ = load_symbols(data, table)
    if symbols.get('_func_8000951C') != RUN:
        raise SystemExit('ERROR: RKSystem::run symbol drift')
    text = next((s for s in segments if s[0]==b'__TEXT'),None)
    ds = next((s for s in segments if s[0]==b'__DATA'),None)
    if not text or text[1]!=BASE or not ds or not ds[1]+ds[4] <= CONTROL < CONTROL+64 <= ds[1]+ds[2]:
        raise SystemExit('ERROR: unclaimed zero-fill session control range missing')
    ncmds, sizeofcmds = struct.unpack_from('<II',data,16)
    if 32+sizeofcmds > TRAMPOLINE-BASE:
        raise SystemExit('ERROR: session bridge would overwrite load commands')
    cursor=32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II',data,cursor)
        if cmd==0x19:
            initprot, nsects = struct.unpack_from('<iI',data,cursor+60)
            segname=data[cursor+8:cursor+24].split(b'\0')[0]
            if segname==b'__TEXT' and initprot!=5 or segname==b'__DATA' and initprot!=3:
                raise SystemExit('ERROR: unexpected bridge memory protections')
            for i in range(nsects):
                sect=cursor+72+i*80
                addr,length=struct.unpack_from('<QQ',data,sect+32)
                for start,end in ((TRAMPOLINE,MAGIC_VM+len(MAGIC)),(CONTROL,CONTROL+64)):
                    if length and addr < end and start < addr+length:
                        raise SystemExit('ERROR: session bridge overlaps a Mach-O section')
        cursor+=size
    return segments


def validate(data):
    validate_bridge(data)  # Build335 guest r3 ABI must survive unchanged.
    segments=layout(data)
    patches=expected_patches()
    for address, expected in patches.items():
        off=vm_to_file(segments,address)
        if data[off:off+len(expected)]!=expected:
            raise SystemExit(f'ERROR: donor frame/return bridge missing at {address:#x}')
    entry_off=vm_to_file(segments,ENTRY)
    entry=bytearray(data[entry_off:entry_off+ENTRY_SIZE])
    struct.pack_into('<I',entry,EXIT_CALL-ENTRY,branch(EXIT_CALL,EXIT_ORIGINAL,0x94000000))
    if hashlib.sha256(entry).hexdigest()!=EXPECTED_ENTRY_SHA:
        raise SystemExit('ERROR: unreviewed instructions changed inside guest startup')
    off=vm_to_file(segments,RUN)
    original=bytearray(data[off:off+RUN_SIZE])
    original[:16]=PROLOGUE
    struct.pack_into('<I',original,FRAME-RUN,FRAME_INSTRUCTION)
    if hashlib.sha256(original).hexdigest()!=EXPECTED_RUN_SHA:
        raise SystemExit('ERROR: unreviewed instructions changed inside RKSystem::run')
    return {'frameBoundary':hex(FRAME),'control':hex(CONTROL),
            'returnPath':'native-epilogue -> guest-main -> RuntimeMain cleanup',
            'gateSha256':hashlib.sha256(gate_bytes()).hexdigest(),
            'preservesBuild335LanguageABI':True, 'guardedGuestExit':hex(EXIT_CALL),
            'preservesHostFloatingPointEnvironment':True}


def patch(path):
    data=bytearray(path.read_bytes())
    validate_bridge(data)
    segments=layout(data)
    off=vm_to_file(segments,ENTRY)
    if hashlib.sha256(data[off:off+ENTRY_SIZE]).hexdigest()!=EXPECTED_ENTRY_SHA:
        raise SystemExit('ERROR: guest startup original instruction hash drift')
    off=vm_to_file(segments,RUN)
    if hashlib.sha256(data[off:off+RUN_SIZE]).hexdigest()!=EXPECTED_RUN_SHA:
        raise SystemExit('ERROR: RKSystem::run original instruction hash drift')
    if any(data[TRAMPOLINE-BASE:MAGIC_VM-BASE+len(MAGIC)]):
        raise SystemExit('ERROR: executable header padding is not unused')
    for address, code in expected_patches().items():
        off=vm_to_file(segments,address); data[off:off+len(code)]=code
    result=validate(data)
    path.write_bytes(data)
    print(json.dumps(result,indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('runtime',type=Path);p.add_argument('--verify',action='store_true');a=p.parse_args()
    if a.verify:print(json.dumps(validate(a.runtime.read_bytes()),indent=2))
    else:patch(a.runtime)
