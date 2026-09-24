#!/usr/bin/env python3
"""Convert the verified official KartPad iOS executable into a loadable donor dylib.

This does not modify code bytes. It rewrites only Mach-O container metadata:
MH_EXECUTE -> MH_DYLIB, removes the executable-only PAGEZERO reservation,
replaces LC_MAIN with an RPATH command, and adds LC_ID_DYLIB in existing header
padding. The output remains an arm64 iPhoneOS image and is re-signed only when
NeoStation itself is signed.
"""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
MH_EXECUTE = 0x2
MH_DYLIB = 0x6
MH_PIE = 0x200000
LC_SEGMENT_64 = 0x19
LC_MAIN = 0x80000028
LC_RPATH = 0x8000001C
LC_ID_DYLIB = 0xD

HEADER = struct.Struct("<IiiIIIII")


def align8(value: int) -> int:
    return (value + 7) & ~7


def patch(source: Path, output: Path, install_name: str) -> None:
    data = bytearray(source.read_bytes())
    if len(data) < HEADER.size:
        raise SystemExit("ERROR: truncated Mach-O")

    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = HEADER.unpack_from(data)
    if magic != MH_MAGIC_64:
        raise SystemExit(f"ERROR: expected thin Mach-O 64, got 0x{magic:08x}")
    if filetype != MH_EXECUTE:
        raise SystemExit(f"ERROR: expected MH_EXECUTE, got {filetype}")

    command_offset = HEADER.size
    command_end = command_offset + sizeofcmds
    if command_end > len(data):
        raise SystemExit("ERROR: invalid load command size")

    main_found = False
    pagezero_found = False
    first_section_offset: int | None = None
    cursor = command_offset
    for _ in range(ncmds):
        if cursor + 8 > command_end:
            raise SystemExit("ERROR: truncated load command")
        cmd, cmdsize = struct.unpack_from("<II", data, cursor)
        if cmdsize < 8 or cursor + cmdsize > command_end:
            raise SystemExit("ERROR: invalid load command")

        if cmd == LC_SEGMENT_64 and cmdsize >= 72:
            segname = bytes(data[cursor + 8 : cursor + 24]).split(b"\0", 1)[0]
            nsects = struct.unpack_from("<I", data, cursor + 64)[0]
            if segname == b"__PAGEZERO":
                # segment_command_64.vmsize
                struct.pack_into("<Q", data, cursor + 32, 0)
                pagezero_found = True
            section_cursor = cursor + 72
            for _section in range(nsects):
                if section_cursor + 80 > cursor + cmdsize:
                    raise SystemExit("ERROR: invalid section table")
                section_file_offset = struct.unpack_from("<I", data, section_cursor + 48)[0]
                if section_file_offset:
                    if first_section_offset is None or section_file_offset < first_section_offset:
                        first_section_offset = section_file_offset
                section_cursor += 80

        if cmd == LC_MAIN:
            if cmdsize != 24:
                raise SystemExit(f"ERROR: unexpected LC_MAIN size {cmdsize}")
            # A dylib cannot have LC_MAIN. Reuse its exact 24-byte slot as an
            # LC_RPATH command so no following command offsets move.
            struct.pack_into("<III", data, cursor, LC_RPATH, 24, 12)
            payload = b"@rpath\0"
            data[cursor + 12 : cursor + 24] = payload.ljust(12, b"\0")
            main_found = True

        cursor += cmdsize

    if not main_found:
        raise SystemExit("ERROR: LC_MAIN not found")
    if not pagezero_found:
        raise SystemExit("ERROR: __PAGEZERO not found")
    if first_section_offset is None:
        raise SystemExit("ERROR: no file-backed section found")

    name = install_name.encode("utf-8") + b"\0"
    id_size = align8(24 + len(name))
    new_end = command_end + id_size
    if new_end > first_section_offset:
        raise SystemExit(
            f"ERROR: no load-command padding ({new_end} > {first_section_offset})"
        )
    if any(data[command_end:new_end]):
        raise SystemExit("ERROR: load-command padding is not empty")

    # struct dylib_command {cmd, cmdsize, name.offset, timestamp,
    # current_version, compatibility_version}
    struct.pack_into("<IIIIII", data, command_end,
                     LC_ID_DYLIB, id_size, 24, 0, 0x10000, 0x10000)
    data[command_end + 24 : command_end + 24 + len(name)] = name

    # mach_header_64: filetype/ncmds/sizeofcmds/flags.
    flags &= ~MH_PIE
    struct.pack_into("<I", data, 12, MH_DYLIB)
    struct.pack_into("<I", data, 16, ncmds + 1)
    struct.pack_into("<I", data, 20, sizeofcmds + id_size)
    struct.pack_into("<I", data, 24, flags)

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--install-name",
        default="@rpath/KartPadRuntime.framework/KartPadRuntime",
    )
    args = parser.parse_args()
    patch(args.source, args.output, args.install_name)
