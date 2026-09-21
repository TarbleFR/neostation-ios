#!/usr/bin/env python3
"""Contracts for atomic reservation and passive, explicit RPCS3 JIT startup."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / 'build-utils/patch_rpcs3_build295_fixed_reservation.py'
DEFERRED = ROOT / 'build-utils/rpcs3/deferred_jit_init.py'

for script in (PATCH, DEFERRED):
    text = script.read_text()
    compile(text, str(script), 'exec')

patch_text = PATCH.read_text()
normalized = ' '.join(patch_text.split())
assert 'NEOSTATION_BUILD295_FIXED_JIT_RESERVATION_V1' in patch_text
assert 'one fixed vm_allocate transaction' in normalized
assert "reservation.count('::vm_allocate(') != 1" in patch_text
assert "'while (reserved < size)' in reservation" in patch_text
assert "'arena_prepare_chunk_size' in reservation" in patch_text
assert 'VM_FLAGS_OVERWRITE' in patch_text  # explicit prohibition is documented/tested
assert '::vm_protect(' in patch_text
assert '::vm_deallocate(' in patch_text
assert 'mmap(address, ...) was only a hint on Darwin' in normalized
assert 'host retry' in patch_text.lower()
assert 'delay' in patch_text.lower()
assert 'cache deletion' in patch_text.lower()
assert 'patch_complete' in patch_text
assert "rpcs3' / 'deferred_jit_init.py" in patch_text

spec = spec_from_file_location('rpcs3_build295_patch', PATCH)
module = module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)

# Focused reservation fixture: replacement drift, idempotence and one complete
# vm_allocate transaction. The full deferred patch is exercised on real source
# by build_rpcs3_embedded_core.sh immediately after this unit test.
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

# Test the real initializer scanner against nested lambdas, comments and string
# literals containing semicolons. A bad cut here could silently reintroduce a
# dyld-time constructor or produce source that only fails late in the Core build.
spec = spec_from_file_location('rpcs3_deferred_jit_patch', DEFERRED)
deferred = module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = deferred
spec.loader.exec_module(deferred)
fixture = '''#if defined(ARCH_ARM64)\nconst auto value = build<void(*)()>("semi;colon", [](auto& out) {\n  // A comment with ; and } must not terminate the initializer.\n  const char* text = "};";\n  if (out) { out(); }\n});\n#endif\n'''
item = deferred._initializer_at(fixture, 'const auto value =')
assert item.statement.endswith('});')
wrapped = deferred._wrap_initializer(
    fixture, item, 'constinit void (*value)() = nullptr;',
    'neostation_build_value', 'void (*)()')
assert 'constinit void (*value)() = nullptr;' in wrapped
assert 'static auto neostation_build_value() -> void (*)()' in wrapped
assert wrapped.count('build<void(*)()>') == 2  # explicit builder + non-iOS path

# Source-level architecture contract. These strings are deliberately strict:
# no second dlopen, no implicit retry and no iOS allocation ensure are allowed.
deferred_text = DEFERRED.read_text() + '\n' + '\n'.join(
    path.read_text() for path in sorted((DEFERRED.parent / 'deferred_jit').glob('*.py'))
)
for token in (
    'NEOSTATION_RPCS3_DEFERRED_JIT_V1',
    'constinit void (*ppu_gateway)(ppu_thread*) = nullptr;',
    'constinit DECLARE(spu_runtime::',
    'asmjit_global_runtime_begin',
    'ppu_trampoline_init_begin',
    'spu_trampoline_init_begin',
    'jit_initialize_failed stage=',
    'jit_initialize_success',
    'reservation_candidate address=',
    'map_code_result success=',
    'writable_alias_result stage=protect',
):
    assert token in deferred_text, token
assert 'dlopen(' not in deferred_text
assert 'retry' not in deferred_text.lower() or 'already failed; relaunch' in deferred_text

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
    assert 'MAP_FIXED | MAP_PRIVATE | MAP_ANON' in jit
    deferred.validate_source_tree(source)

print('PASS: RPCS3 reservation is atomic and all iOS JIT initialization is explicit')
