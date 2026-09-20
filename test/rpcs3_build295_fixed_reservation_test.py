#!/usr/bin/env python3
"""Contract test for the Build 295 exact low-VA RPCS3 reservation."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / 'build-utils/patch_rpcs3_build295_fixed_reservation.py'
text = PATCH.read_text()
compile(text, str(PATCH), 'exec')

assert "NEOSTATION_BUILD295_FIXED_JIT_RESERVATION_V1" in text
assert "::vm_allocate(" in text
assert "VM_FLAGS_FIXED | jit_vm_tag" in text
assert "VM_FLAGS_OVERWRITE" in text  # explicit prohibition is documented/tested
assert "if (result == KERN_SUCCESS)" in text
assert "::vm_deallocate(" in text
assert "::vm_protect(" in text
assert "mmap(address, ...) is only a hint on Darwin" in text
assert "host retry" in text.lower()
assert "delay" in text.lower()

if len(sys.argv) > 1:
    source = Path(sys.argv[1])
    jit = (source / 'Utilities/JITIOS.cpp').read_text()
    assert "NEOSTATION_BUILD295_FIXED_JIT_RESERVATION_V1" in jit
    assert "#include <mach/mach_vm.h>" not in jit
    reservation = jit.split("u8* reserve_arena_layout(", 1)[1].split(
        "\nu8* reserve_code_data_layout(", 1
    )[0]
    assert "::vm_allocate(" in reservation
    assert "VM_FLAGS_FIXED | jit_vm_tag" in reservation
    assert "VM_FLAGS_OVERWRITE" not in reservation
    assert "::mmap(" not in reservation
    assert "::mach_vm_allocate(" not in reservation
    assert 'set_error("NEOSTATION_BUILD295_FIXED_JIT_RESERVATION_V1: Unable to reserve the JIT arena layout' in jit
    # Final RX/RW replacement remains separate and may still use MAP_FIXED only
    # after the Core owns the complete reservation.
    assert "MAP_FIXED | MAP_PRIVATE | MAP_ANON" in jit

print("PASS: Build 295 reserves exact low VA without overwriting occupied mappings")
