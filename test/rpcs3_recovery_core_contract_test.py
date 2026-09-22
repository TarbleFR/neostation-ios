#!/usr/bin/env python3
from pathlib import Path

root=Path(__file__).resolve().parents[1]
build=(root/'build-utils/build_rpcs3_recovery_core.sh').read_text()
patch=(root/'build-utils/patch_rpcs3_build301_passive_dlopen.py').read_text()

assert build.count('patch_rpcs3_build266_v09_core.py') == 1
assert build.count('patch_rpcs3_build301_passive_dlopen.py') == 1
assert build.count('patch_rpcs3_build303_restartable_lifecycle.py') == 1
assert 'patch_rpcs3_build295_fixed_reservation.py' not in build

# Build 302's marker is intentionally mentioned only by the negative guard
# that rejects a materialized recovery source if the fixed reservation returns.
assert 'grep -R -q "NEOSTATION_BUILD295_FIXED_JIT_RESERVATION_V1\\|NEOSTATION_BUILD302_RESERVED_STARTUP_V1"' in build
assert 'Recovery Core unexpectedly contains fixed-reservation markers' in build

assert 'mode=mmap_hint_exact' in patch
assert 'must be applied before/without Build 295' in patch
assert 'VM_FLAGS_FIXED | jit_vm_tag' not in patch

print('PASS: recovery Core is Build266 allocator + Build301 passive dlopen + restartable lifecycle, with Build295/302 excluded')
