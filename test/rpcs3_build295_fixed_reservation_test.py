#!/usr/bin/env python3
"""Contract test for the exact, atomic low-VA RPCS3 reservation."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / 'build-utils/patch_rpcs3_build295_fixed_reservation.py'
text = PATCH.read_text()
compile(text, str(PATCH), 'exec')

assert "NEOSTATION_BUILD295_FIXED_JIT_RESERVATION_V1" in text
assert "Reserve the whole candidate in one fixed vm_allocate transaction" in text
assert "reservation.count('::vm_allocate(') != 1" in text
assert "'while (reserved < size)' in reservation" in text
assert "'arena_prepare_chunk_size' in reservation" in text
assert "VM_FLAGS_OVERWRITE" in text  # explicit prohibition is documented/tested
assert "::vm_protect(" in text
assert "::vm_deallocate(" in text
assert "mmap(address, ...) was only a hint on Darwin" in text
assert "host retry" in text.lower()
assert "delay" in text.lower()
assert "cache deletion" in text.lower()

spec = spec_from_file_location('rpcs3_build295_patch', PATCH)
module = module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

# Exercise the real transformation before starting a full RPCS3 build. This
# catches replacement drift, verifies idempotence, and proves that the final
# reservation no longer owns a candidate through multiple chunk allocations.
with tempfile.TemporaryDirectory(prefix='rpcs3-build295-') as directory:
    root = Path(directory)
    utilities = root / 'Utilities'
    utilities.mkdir(parents=True)
    source = (
        '#include <mach/mach.h>\n'
        '#define NEOSTATION_DYNAMIC_JIT_V5 1\n'
        + module.OLD
        + '\n\nu8* reserve_code_data_layout(usz, u8*&, usz&) noexcept { return nullptr; }\n'
        + '\nvoid marker_error() {\n'
        + '  set_error("Unable to reserve the JIT arena layout in low virtual address space (code=" + std::to_string(1));\n'
        + '}\n'
    )
    path = utilities / 'JITIOS.cpp'
    path.write_text(source)
    module.patch(root)
    first = path.read_text()
    module.patch(root)
    second = path.read_text()
    assert first == second
    module.validate_atomic(first)
    reservation = module.reservation_body(first)
    assert reservation.count('::vm_allocate(') == 1
    assert 'static_cast<vm_size_t>(size)' in reservation
    assert 'while (reserved < size)' not in reservation
    assert 'candidate + reserved' not in reservation
    assert 'arena_prepare_chunk_size' not in reservation
    assert 'VM_FLAGS_OVERWRITE' not in reservation
    assert '::mmap(' not in reservation
    assert '::mach_vm_allocate(' not in reservation
    assert '::vm_protect(' in reservation
    assert '::vm_deallocate(' in reservation
    assert 'NEOSTATION_BUILD295_FIXED_JIT_RESERVATION_V1: Unable' in first

if len(sys.argv) > 1:
    source = Path(sys.argv[1])
    jit = (source / 'Utilities/JITIOS.cpp').read_text()
    module.validate_atomic(jit)
    reservation = module.reservation_body(jit)
    assert '#include <mach/mach_vm.h>' not in jit
    assert reservation.count('::vm_allocate(') == 1
    assert 'static_cast<vm_size_t>(size)' in reservation
    assert 'while (reserved < size)' not in reservation
    assert 'candidate + reserved' not in reservation
    assert 'arena_prepare_chunk_size' not in reservation
    assert 'VM_FLAGS_OVERWRITE' not in reservation
    assert '::mmap(' not in reservation
    assert '::mach_vm_allocate(' not in reservation
    # Final RX/RW replacement remains separate and may still use MAP_FIXED only
    # after the Core atomically owns the complete reservation.
    assert 'MAP_FIXED | MAP_PRIVATE | MAP_ANON' in jit

print('PASS: Build 295 reserves each complete low-VA candidate atomically')
