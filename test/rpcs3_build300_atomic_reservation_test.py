#!/usr/bin/env python3
"""Contract tests for Build 300's atomic low-VA JIT reservation."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / 'build-utils/patch_rpcs3_build300_atomic_reservation.py'
text = PATCH.read_text()
compile(text, str(PATCH), 'exec')

assert 'NEOSTATION_BUILD300_ATOMIC_JIT_RESERVATION_V1' in text
assert 'Reserve the complete candidate with one fixed vm_allocate transaction' in text
assert "reservation.count('::vm_allocate(') != 1" in text
assert "'while (reserved < size)' in reservation" in text
assert "'arena_prepare_chunk_size' in reservation" in text
assert 'VM_FLAGS_OVERWRITE' in text  # explicit prohibition is part of the contract
assert 'no retry' in text.lower()
assert 'delay' in text.lower()
assert 'cache deletion' in text.lower()

spec = spec_from_file_location('rpcs3_build300_patch', PATCH)
module = module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

# Exercise the actual patch transformation and its idempotent verification on a
# minimal source fixture. This catches replacement drift before macOS CI spends
# time compiling RPCS3's thousands of translation units.
with tempfile.TemporaryDirectory(prefix='rpcs3-build300-') as directory:
    root = Path(directory)
    utilities = root / 'Utilities'
    utilities.mkdir(parents=True)
    source = (
        '#include <mach/mach.h>\n'
        + module.OLD
        + '\n\nu8* reserve_code_data_layout(usz, u8*&, usz&) noexcept { return nullptr; }\n'
        + '\nvoid marker_error() {\n'
        + '  set_error("NEOSTATION_BUILD295_FIXED_JIT_RESERVATION_V1: Unable to reserve the JIT arena layout in low virtual address space (code=" + std::to_string(1));\n'
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
    assert '::vm_protect(' in reservation
    assert '::vm_deallocate(' in reservation
    assert 'NEOSTATION_BUILD300_ATOMIC_JIT_RESERVATION_V1: Unable' in first

print('PASS: Build 300 reserves each complete JIT candidate atomically')
