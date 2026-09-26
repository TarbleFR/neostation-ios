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
SELECT_PROFILE = 0x100059EC8
SELECT_PROFILE_SIZE = 0x394
SELECT_PROFILE_SHA = '3a06e5aaeab0916914d46d6bc240018af32a68ffd5cbc69ee628aea319b4d159'
SELECT_FROZEN_BRANCH = 0x100059F1C
SELECT_FROZEN_ORIGINAL = 0x540002A0  # b.eq throw("cannot change ... after finalization")
SELECT_FROZEN_RETURN = 0x10005A0FC  # mutex unlock + normal epilogue

# The donor's DVD host index is process-lifetime, while guest RAM is rebuilt for
# every RuntimeMain. Stock DVDInit returns immediately once g_dvdInitialized is
# true, leaving the second guest with no DVD globals/FST. We re-enter DVDInit,
# but make RegisterFileEntry a no-op after the first completed index. This
# preserves the host vectors/map without duplicating thousands of entries, while
# BuildAndPublishRuntimeFst republishes them into the fresh guest memory.
DVD_INIT = 0x100118344
DVD_INIT_SIZE = 0x3604
DVD_INIT_SHA = 'ef88d7116fde476a270575f6a97188a169d66d895945ae6da22c1ebb6600a400'
DVD_INIT_GUARD = 0x100118380
DVD_INIT_GUARD_ORIGINAL = 0x3701AE29
DVD_INITIALIZED = 0x1051B9490
REGISTER_FILE = 0x10012E684
REGISTER_FILE_SIZE = 0x2F4
REGISTER_FILE_SHA = 'cd651a05e6f49bb24997a55fa35ee22c3e0e2a9b0fcc89232867a185f339f908'
REGISTER_FILE_PROLOGUE = bytes.fromhex('ffc302d1f85f07a9f65708a9f44f09a9')
DVD_REGISTER_GATE = BASE + 0x8A00
DVD_DIRECTORY_GATE = BASE + 0x8B00
DVD_DIRECTORY_LOOP = 0x10011ACA8
DVD_DIRECTORY_NEXT = 0x10011AC9C
DVD_DIRECTORY_ORIGINAL = 0x39C05E68  # ldrsb w8, [x19, #0x17]
PROLOGUE = bytes.fromhex('ff0303d1fc6f06a9fa6707a9f85f08a9')
FRAME_INSTRUCTION = 0x29424666  # ldp w6, w17, [x19, #0x10]


def branch(pc, target, opcode=0x14000000):
    delta = target - pc
    if delta % 4 or not -(1 << 27) <= delta < 1 << 27:
        raise SystemExit('ERROR: session bridge branch out of range')
    return opcode | ((delta // 4) & 0x3ffffff)


def cond_branch(pc, target, cond=0):
    delta = target - pc
    if delta % 4 or not -(1 << 20) <= delta < (1 << 20):
        raise SystemExit('ERROR: conditional branch out of range')
    return 0x54000000 | (((delta // 4) & 0x7ffff) << 5) | (cond & 0xf)


def pair(load, vector, r1, r2, offset):
    unit = 16 if vector else 8
    if offset % unit or not 0 <= offset // unit < 64:
        raise SystemExit('ERROR: invalid session bridge stack pair')
    op = (0xAD400000 if load else 0xAD000000) if vector else (0xA9400000 if load else 0xA9000000)
    return op | ((offset // unit) << 15) | (r2 << 10) | (31 << 5) | r1


def ldrb_w(rt, rn, offset):
    if not 0 <= offset <= 0xfff:
        raise SystemExit('ERROR: invalid DVD gate byte offset')
    return 0x39400000 | (offset << 10) | (rn << 5) | rt


def cbz_w(rt, pc, target):
    delta = target - pc
    if delta % 4 or not -(1 << 20) <= delta < (1 << 20):
        raise SystemExit('ERROR: DVD gate conditional branch out of range')
    return 0x34000000 | (((delta // 4) & 0x7ffff) << 5) | rt


def cbnz_w(rt, pc, target):
    return cbz_w(rt, pc, target) | 0x01000000


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


def dvd_register_gate_bytes():
    # If the first session already built the host-side disc index, registration
    # is deliberately skipped. Otherwise execute the exact original prologue.
    code = [
        encode_adrp(16, DVD_REGISTER_GATE, DVD_INITIALIZED),
        ldrb_w(17, 16, DVD_INITIALIZED & 0xfff),
        cbz_w(17, DVD_REGISTER_GATE + 8, DVD_REGISTER_GATE + 16),
        0xD65F03C0,  # ret: keep the existing host index on session >= 2
    ]
    return words(code) + REGISTER_FILE_PROLOGUE + words([
        branch(DVD_REGISTER_GATE + 32, REGISTER_FILE + 16)
    ])


def dvd_directory_gate_bytes():
    # Session 2 reuses the published host index. That vector now contains
    # synthetic directory nodes (including "/"), whereas BuildImage takes
    # files only. Skip directory nodes when reconstructing registrations;
    # keep the exact original file-copy instruction and loop increment.
    return words([
        ldrb_w(8, 19, 0x38),
        cbnz_w(8, DVD_DIRECTORY_GATE + 4, DVD_DIRECTORY_GATE + 16),
        DVD_DIRECTORY_ORIGINAL,
        branch(DVD_DIRECTORY_GATE + 12, DVD_DIRECTORY_LOOP + 4),
        branch(DVD_DIRECTORY_GATE + 16, DVD_DIRECTORY_NEXT),
    ])


def expected_patches():
    entry = words([encode_adrp(16, RUN, CONTROL),
                   ldr_x(16,16,CONTROL & 0xfff),0xD61F0200,0xD503201F])
    trampoline = PROLOGUE + words([branch(TRAMPOLINE+16,RUN+16)])
    return {RUN:entry, FRAME:words([branch(FRAME,GATE)]),
            SELECT_FROZEN_BRANCH: words([cond_branch(SELECT_FROZEN_BRANCH, SELECT_FROZEN_RETURN, 0)]),
            DVD_INIT_GUARD: words([0xD503201F]),
            REGISTER_FILE: words([branch(REGISTER_FILE, DVD_REGISTER_GATE),
                                  0xD503201F, 0xD503201F, 0xD503201F]),
            DVD_REGISTER_GATE: dvd_register_gate_bytes(),
            DVD_DIRECTORY_LOOP: words([branch(DVD_DIRECTORY_LOOP, DVD_DIRECTORY_GATE)]),
            DVD_DIRECTORY_GATE: dvd_directory_gate_bytes(),
            TRAMPOLINE:trampoline, GATE:gate_bytes(), MAGIC_VM:MAGIC,
            EXIT_CALL:words([branch(EXIT_CALL,EXIT_GATE,0x94000000)]),
            EXIT_GATE:words([encode_adrp(16,EXIT_GATE,CONTROL),
                             ldr_x(16,16,(CONTROL & 0xfff)+16),0xD61F0200])}


def layout(data):
    segments, table = parse_macho(data)
    symbols, _ = load_symbols(data, table)
    if symbols.get('_func_8000951C') != RUN:
        raise SystemExit('ERROR: RKSystem::run symbol drift')
    if symbols.get('__ZN26TranslatedFunctionRegistry13SelectProfileEPKc') != SELECT_PROFILE:
        raise SystemExit('ERROR: translated profile selector symbol drift')
    if symbols.get('_DVDInit_8015EA1C') != DVD_INIT:
        raise SystemExit('ERROR: DVDInit symbol drift')
    if symbols.get('__ZL17RegisterFileEntryNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEERKNS_4__fs10filesystem4pathEj') != REGISTER_FILE:
        raise SystemExit('ERROR: DVD RegisterFileEntry symbol drift')
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
    select_off=vm_to_file(segments,SELECT_PROFILE)
    select_original=bytearray(data[select_off:select_off+SELECT_PROFILE_SIZE])
    branch_offset=SELECT_FROZEN_BRANCH-SELECT_PROFILE
    struct.pack_into('<I',select_original,branch_offset,SELECT_FROZEN_ORIGINAL)
    if hashlib.sha256(select_original).hexdigest()!=SELECT_PROFILE_SHA:
        raise SystemExit('ERROR: unreviewed instructions changed inside translated profile selector')
    dvd_off=vm_to_file(segments,DVD_INIT)
    dvd_original=bytearray(data[dvd_off:dvd_off+DVD_INIT_SIZE])
    struct.pack_into('<I',dvd_original,DVD_INIT_GUARD-DVD_INIT,DVD_INIT_GUARD_ORIGINAL)
    struct.pack_into('<I',dvd_original,DVD_DIRECTORY_LOOP-DVD_INIT,DVD_DIRECTORY_ORIGINAL)
    if hashlib.sha256(dvd_original).hexdigest()!=DVD_INIT_SHA:
        raise SystemExit('ERROR: unreviewed instructions changed inside DVDInit')
    register_off=vm_to_file(segments,REGISTER_FILE)
    register_original=bytearray(data[register_off:register_off+REGISTER_FILE_SIZE])
    register_original[:16]=REGISTER_FILE_PROLOGUE
    if hashlib.sha256(register_original).hexdigest()!=REGISTER_FILE_SHA:
        raise SystemExit('ERROR: unreviewed instructions changed inside DVD file registration')
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
            'preservesHostFloatingPointEnvironment':True,
            'reentrantFrozenProfile':True,
            'frozenProfileBranch':hex(SELECT_FROZEN_BRANCH),
            'reentrantDvdGuestPublish':True,
            'dvdHostIndexReuseGate':hex(DVD_REGISTER_GATE),
            'dvdDirectoryReentryGate':hex(DVD_DIRECTORY_GATE)}


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
    select_off=vm_to_file(segments,SELECT_PROFILE)
    if hashlib.sha256(data[select_off:select_off+SELECT_PROFILE_SIZE]).hexdigest()!=SELECT_PROFILE_SHA:
        raise SystemExit('ERROR: translated profile selector original instruction hash drift')
    if struct.unpack_from('<I',data,vm_to_file(segments,SELECT_FROZEN_BRANCH))[0]!=SELECT_FROZEN_ORIGINAL:
        raise SystemExit('ERROR: frozen profile branch original instruction drift')
    dvd_off=vm_to_file(segments,DVD_INIT)
    if hashlib.sha256(data[dvd_off:dvd_off+DVD_INIT_SIZE]).hexdigest()!=DVD_INIT_SHA:
        raise SystemExit('ERROR: DVDInit original instruction hash drift')
    if struct.unpack_from('<I',data,vm_to_file(segments,DVD_INIT_GUARD))[0]!=DVD_INIT_GUARD_ORIGINAL:
        raise SystemExit('ERROR: DVDInit process-lifetime guard instruction drift')
    if struct.unpack_from('<I',data,vm_to_file(segments,DVD_DIRECTORY_LOOP))[0]!=DVD_DIRECTORY_ORIGINAL:
        raise SystemExit('ERROR: DVDInit directory registration instruction drift')
    register_off=vm_to_file(segments,REGISTER_FILE)
    if hashlib.sha256(data[register_off:register_off+REGISTER_FILE_SIZE]).hexdigest()!=REGISTER_FILE_SHA:
        raise SystemExit('ERROR: DVD file registration original instruction hash drift')
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
