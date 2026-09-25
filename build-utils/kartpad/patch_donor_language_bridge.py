#!/usr/bin/env python3
"""Patch the verified KartPad donor runtime so SCGetLanguage is host-controlled.

The official RMCP01 translated runtime calls func_801B1D0C (SCGetLanguage)
directly from multiple generated call sites, so changing only SYSCONF or the
runtime registry is not sufficient for an already-running embedded session.

The translated entry point has ABI void(CpuContext*), NOT uint8_t(void).
The native x0 argument points to a 464-byte CpuContext; guest r3 is the native
uint32_t at byte offset 12. The Build 334 stub loaded the language into w0 and
returned, leaving guest r3 stale (and truncating the context pointer in x0).
Generated callers then used that stale r3 to select localized game resources.

For the pinned official v0.5.1 iOS binary, replace the first four instructions:
    adrp x8, <language slot page>
    ldrb w8, [x8, <language slot offset>]
    str  w8, [x0, #12]  // CpuContext.gpr[3], native little-endian uint32_t
    ret
Only guest r3 and the caller-saved native x8 are modified. The byte-sized
language slot is an alignment byte immediately after the exported bool
g_dynamicAspectRatioEnabled and before the next symbol. NeoStation writes
that byte through dlsym(). ADRP remains ASLR-safe under page-aligned slides.

Every address and original byte sequence is discovered/validated from the Mach-O
symbol table. Any upstream drift aborts the build instead of patching blindly.
"""
from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
HEADER = struct.Struct("<IiiIIIII")
NLIST_64 = struct.Struct("<IBBHQ")

SCGETLANGUAGE_SYMBOL = "_func_801B1D0C"
ASPECT_SYMBOL = "_g_dynamicAspectRatioEnabled"
# Include the fourth overwritten instruction, not just the old three.
EXPECTED_PROLOGUE = bytes.fromhex("f85fbca9f65701a9f44f02a9fd7b03a9")
CPU_CONTEXT_R3_OFFSET = 12
CPU_CONTEXT_SIZE = 464
BRIDGE_SIZE = 16


def parse_macho(data: bytes):
    if len(data) < HEADER.size:
        raise SystemExit("ERROR: truncated Mach-O")
    magic, _cpu, _sub, _type, ncmds, sizeofcmds, _flags, _res = HEADER.unpack_from(data)
    if magic != MH_MAGIC_64:
        raise SystemExit(f"ERROR: expected thin arm64 Mach-O, got 0x{magic:08x}")

    if _cpu != 0x0100000C or _type != 6:
        raise SystemExit("ERROR: expected converted arm64 MH_DYLIB")

    command_end = HEADER.size + sizeofcmds
    if command_end > len(data):
        raise SystemExit("ERROR: invalid Mach-O load-command range")

    segments = []
    symtab = None
    cursor = HEADER.size
    for _ in range(ncmds):
        if cursor + 8 > command_end:
            raise SystemExit("ERROR: truncated load command")
        cmd, cmdsize = struct.unpack_from("<II", data, cursor)
        if cmdsize < 8 or cursor + cmdsize > command_end:
            raise SystemExit("ERROR: invalid load command")

        if cmd == LC_SEGMENT_64 and cmdsize >= 72:
            segname = bytes(data[cursor + 8:cursor + 24]).split(b"\0", 1)[0]
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, cursor + 24)
            segments.append((segname, vmaddr, vmsize, fileoff, filesize))
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from("<IIII", data, cursor + 8)

        cursor += cmdsize

    if symtab is None:
        raise SystemExit("ERROR: donor runtime has no LC_SYMTAB")
    return segments, symtab


def load_symbols(data: bytes, symtab):
    symoff, nsyms, stroff, strsize = symtab
    if symoff + nsyms * NLIST_64.size > len(data) or stroff + strsize > len(data):
        raise SystemExit("ERROR: invalid Mach-O symbol table")
    symbols = {}
    ordered = []
    for index in range(nsyms):
        n_strx, _n_type, _n_sect, _n_desc, n_value = NLIST_64.unpack_from(
            data, symoff + index * NLIST_64.size
        )
        if n_strx >= strsize:
            continue
        start = stroff + n_strx
        end = data.find(b"\0", start, stroff + strsize)
        if end < 0:
            continue
        name = data[start:end].decode("utf-8", "replace")
        if name:
            symbols[name] = n_value
            if n_value:
                ordered.append((n_value, name))
    ordered.sort()
    return symbols, ordered


def vm_to_file(segments, address: int) -> int:
    for _name, vmaddr, _vmsize, fileoff, filesize in segments:
        if vmaddr <= address < vmaddr + filesize:
            return fileoff + (address - vmaddr)
    raise SystemExit(f"ERROR: VM address 0x{address:x} is not file-backed")


def encode_adrp(rd: int, pc: int, target: int) -> int:
    pc_page = pc & ~0xFFF
    target_page = target & ~0xFFF
    delta_pages = (target_page - pc_page) >> 12
    if not -(1 << 20) <= delta_pages < (1 << 20):
        raise SystemExit("ERROR: language slot is outside ADRP range")
    imm21 = delta_pages & ((1 << 21) - 1)
    immlo = imm21 & 0x3
    immhi = (imm21 >> 2) & 0x7FFFF
    return 0x90000000 | (immlo << 29) | (immhi << 5) | rd


def encode_ldrb_w(rt: int, rn: int, offset: int) -> int:
    if not 0 <= offset <= 0xFFF:
        raise SystemExit("ERROR: language byte is outside LDRB imm12 range")
    return 0x39400000 | (offset << 10) | (rn << 5) | rt


def encode_str_w(rt: int, rn: int, offset: int) -> int:
    if offset < 0 or offset % 4 or offset // 4 > 0xFFF:
        raise SystemExit("ERROR: context offset is outside STR W imm12 range")
    return 0xB9000000 | ((offset // 4) << 10) | (rn << 5) | rt


def bridge_bytes(function_vm: int, language_slot_vm: int) -> bytes:
    return struct.pack(
        "<IIII",
        encode_adrp(8, function_vm, language_slot_vm),
        encode_ldrb_w(8, 8, language_slot_vm & 0xFFF),
        encode_str_w(8, 0, CPU_CONTEXT_R3_OFFSET),
        0xD65F03C0,
    )


def bridge_layout(data: bytes) -> tuple[int, int, int]:
    segments, symtab = parse_macho(data)
    symbols, ordered = load_symbols(data, symtab)

    try:
        function_vm = symbols[SCGETLANGUAGE_SYMBOL]
        aspect_vm = symbols[ASPECT_SYMBOL]
    except KeyError as exc:
        raise SystemExit(f"ERROR: required donor symbol missing: {exc.args[0]}") from exc

    language_slot_vm = aspect_vm + 1
    # The pinned image intentionally uses an alignment gap after three adjacent
    # bool globals. Abort if another symbol ever claims our byte.
    following = [(addr, name) for addr, name in ordered if addr > aspect_vm]
    if not following:
        raise SystemExit("ERROR: cannot validate language-slot padding")
    next_vm, next_name = following[0]
    if next_vm <= language_slot_vm:
        raise SystemExit(
            f"ERROR: language slot overlaps {next_name} at 0x{next_vm:x}"
        )

    # Neither the code write nor the host-owned byte may cross its segment.
    code = next((s for s in segments if s[0] == b"__TEXT"
                 and s[1] <= function_vm
                 and function_vm + BRIDGE_SIZE <= s[1] + s[4]), None)
    slot = next((s for s in segments if s[0] == b"__DATA"
                 and s[1] <= language_slot_vm < s[1] + s[2]), None)
    if code is None or slot is None:
        raise SystemExit("ERROR: language bridge is outside expected TEXT/DATA segments")
    following_functions = [addr for addr, _ in ordered if addr > function_vm]
    if not following_functions or following_functions[0] < function_vm + BRIDGE_SIZE:
        raise SystemExit("ERROR: language bridge would overwrite the next symbol")
    function_file = vm_to_file(segments, function_vm)
    if function_file + BRIDGE_SIZE > len(data):
        raise SystemExit("ERROR: truncated SCGetLanguage function")
    return function_vm, function_file, language_slot_vm


def validate_bridge(data: bytes) -> dict:
    function_vm, function_file, language_slot_vm = bridge_layout(data)
    actual = bytes(data[function_file:function_file + BRIDGE_SIZE])
    expected = bridge_bytes(function_vm, language_slot_vm)
    if actual != expected:
        raise SystemExit(
            "ERROR: SCGetLanguage guest ABI bridge missing or invalid; "
            "expected CpuContext.r3 store, not a native w0 return "
            f"(got {actual.hex()}, expected {expected.hex()})"
        )
    return {
        "abi": "void(CpuContext*)",
        "guestReturnOffset": CPU_CONTEXT_R3_OFFSET,
        "preservesContextPointer": True,
        "functionVm": hex(function_vm),
        "languageSlotVm": hex(language_slot_vm),
        "instructions": actual.hex(),
    }


def patch(path: Path) -> None:
    data = bytearray(path.read_bytes())
    function_vm, function_file, language_slot_vm = bridge_layout(data)
    original = bytes(data[function_file:function_file + len(EXPECTED_PROLOGUE)])
    if original != EXPECTED_PROLOGUE:
        raise SystemExit(
            "ERROR: SCGetLanguage donor prologue drifted; refusing binary patch "
            f"(got {original.hex()})"
        )

    replacement = bridge_bytes(function_vm, language_slot_vm)
    data[function_file:function_file + len(replacement)] = replacement
    report = validate_bridge(data)
    path.write_bytes(data)
    print("Patched donor SCGetLanguage guest ABI: " + json.dumps(report, sort_keys=True))



if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.verify:
        print(json.dumps(validate_bridge(args.runtime.read_bytes()), indent=2))
    else:
        patch(args.runtime)
