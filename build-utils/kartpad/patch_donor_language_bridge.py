#!/usr/bin/env python3
"""Patch the verified KartPad donor runtime so SCGetLanguage is host-controlled.

The official RMCP01 translated runtime calls func_801B1D0C (SCGetLanguage)
directly from multiple generated call sites, so changing only SYSCONF or the
runtime registry is not sufficient for an already-running embedded session.

For the pinned official v0.5.1 iOS binary, this script replaces only the first
three arm64 instructions of func_801B1D0C with:
    adrp x8, <language slot page>
    ldrb w0, [x8, <language slot offset>]
    ret
The byte-sized language slot is an alignment byte immediately after the exported
bool g_dynamicAspectRatioEnabled and before the next symbol. NeoStation writes
that byte through dlsym(). The patch is ASLR-safe because ADRP is page-relative.

Every address and original byte sequence is discovered/validated from the Mach-O
symbol table. Any upstream drift aborts the build instead of patching blindly.
"""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
HEADER = struct.Struct("<IiiIIIII")
NLIST_64 = struct.Struct("<IBBHQ")

SCGETLANGUAGE_SYMBOL = "_func_801B1D0C"
ASPECT_SYMBOL = "_g_dynamicAspectRatioEnabled"
EXPECTED_PROLOGUE = bytes.fromhex("f85fbca9f65701a9f44f02a9")


def parse_macho(data: bytes):
    if len(data) < HEADER.size:
        raise SystemExit("ERROR: truncated Mach-O")
    magic, _cpu, _sub, _type, ncmds, sizeofcmds, _flags, _res = HEADER.unpack_from(data)
    if magic != MH_MAGIC_64:
        raise SystemExit(f"ERROR: expected thin arm64 Mach-O, got 0x{magic:08x}")

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


def patch(path: Path) -> None:
    data = bytearray(path.read_bytes())
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

    function_file = vm_to_file(segments, function_vm)
    original = bytes(data[function_file:function_file + len(EXPECTED_PROLOGUE)])
    if original != EXPECTED_PROLOGUE:
        raise SystemExit(
            "ERROR: SCGetLanguage donor prologue drifted; refusing binary patch "
            f"(got {original.hex()})"
        )

    adrp = encode_adrp(8, function_vm, language_slot_vm)
    ldrb = encode_ldrb_w(0, 8, language_slot_vm & 0xFFF)
    replacement = struct.pack("<III", adrp, ldrb, 0xD65F03C0)
    data[function_file:function_file + len(replacement)] = replacement
    path.write_bytes(data)

    print(
        "Patched donor SCGetLanguage: "
        f"func=0x{function_vm:x} file=0x{function_file:x} "
        f"slot=0x{language_slot_vm:x} next={next_name}@0x{next_vm:x} "
        f"bytes={replacement.hex()}"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    args = parser.parse_args()
    patch(args.runtime)
