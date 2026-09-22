#!/usr/bin/env python3
"""Guard the single game launch path and the passive Core artifact boundary."""
import hashlib
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
service = (ROOT / 'lib/services/rpcs3_internal_service.dart').read_text()
launcher = (ROOT / 'lib/services/rpcs3_launch_service.dart').read_text()
bridge = (ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
dart_bridge = (ROOT / 'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart').read_text()
workflow = (ROOT / '.github/workflows/ios-ci.yml').read_text()
validator = (ROOT / 'build-utils/validate_rpcs3_ipa.py').read_text()
sys.path.insert(0, str(ROOT / 'build-utils'))
spec = importlib.util.spec_from_file_location(
    'validate_rpcs3_ipa', ROOT / 'build-utils/validate_rpcs3_ipa.py'
)
ipa_validator = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(ipa_validator)

for retired in (
    'Rpcs3StartupTransaction', 'abortStartup', 'verifyJitExecution',
    'reserveAddressSpace', '_bootCrashMarker', 'bootProgress',
):
    assert retired not in service, retired

assert launcher.count('ensureGameplayInitialized()') == 1
assert service.count('Rpcs3InternalBridge.initialize(') == 1
assert service.count('Rpcs3InternalBridge.prepareJit(') == 1
order = [
    service.index('LocalDevVpnRouteService.ensureReachable'),
    service.index('PairingFileService.hasStoredPairingFile'),
    service.index('Rpcs3InternalBridge.prepareJit'),
    service.index('Rpcs3InternalBridge.initialize'),
    service.index('Rpcs3InternalBridge.completeJit'),
]
assert order == sorted(order), order

assert bridge.count('handle = dlopen(') == 1
assert bridge.count('self->_api.initialize(&options)') == 1
assert 'NEOSTATION_RPCS3_SINGLE_DLOPEN_V1' in bridge
for retired in (
    '_startupEntered', 'abortStartup', 'verifyJitExecution',
    'RPCS3JitTransactionIsClosed', 'Rpcs3ArenaReservation',
    'reset_failed_startup', 'isEqualToString:@"shutdown"',
):
    assert retired not in bridge, retired

handoff = bridge.index('if (!RPCS3JitConfirmCoreLoadHandoff())')
dlopen = bridge.index('handle = dlopen(')
initialize = bridge.index('self->_api.initialize(&options)')
launch = bridge.index('if ([call.method isEqualToString:@"launchGame"])')
self_test = bridge.index('rpcs3_ios_run_llvm_self_test', launch)
boot = bridge.index('self->_api.boot_game', launch)
assert handoff < dlopen < initialize < launch < self_test < boot

stop_start = bridge.index('- (void)stopAndDismiss:')
stop_body = bridge[stop_start:]
assert 'self->_api.stop_emulation()' in stop_body
assert 'self->_api.shutdown()' not in stop_body

assert 'abortStartup' not in dart_bridge
assert 'verifyJitExecution' not in dart_bridge

assert 'RPCS3Core-' + '${{ env.RPCS3_CORE_HOST_SHA }}' in workflow
assert '--core-identity build/fast-native/rpcs3-core-identity.json' in workflow
assert 'NEOSTATION_BUILD301_PASSIVE_DLOPEN_V1' in validator
assert 'NEOSTATION_EXACT_ATOMIC_JIT_RESERVATION_V1' in validator
assert 'patch_rpcs3_build301_passive_dlopen.py' not in workflow
assert 'patch_rpcs3_build303_restartable_lifecycle.py' not in workflow

manifest = json.loads((ROOT / 'build-utils/rpcs3/canonical-source.json').read_text())
payload = b'identity-bound Core artifact bytes'
expected_core_commit = '0d8072f9f80250ad19502a856d5c5fa1a1163b07'
identity = {
    'schema_version': 1,
    'repository': 'https://github.com/TarbleFR/neostation-ios',
    'host_commit': expected_core_commit,
    'source_commit': manifest['upstream_commit'],
    'source_patch_sha256': manifest['patch_sha256'],
    'abi_version': 30,
    'architectures': ['arm64'],
    'sha256': hashlib.sha256(payload).hexdigest(),
    'lifecycle_marker': ipa_validator.CORE_LIFECYCLE_MARKER,
    'allocator_marker': ipa_validator.CORE_ALLOCATOR_MARKER,
    'device_runtime_tested': False,
}

with tempfile.TemporaryDirectory() as temp:
    identity_path = Path(temp) / 'identity.json'
    identity_path.write_text(json.dumps(identity))
    assert ipa_validator.validate_core_identity(payload, identity_path, expected_core_commit) == identity

    # A stale binary, different build commit or ABI must fail before the
    # Core is installed into the app. The same check repeats inside the IPA.
    for data, host_commit in (
        (payload + b'corruption', expected_core_commit),
        (payload, 'f' * 40),
    ):
        try:
            ipa_validator.validate_core_identity(data, identity_path, host_commit)
        except ipa_validator.ValidationError:
            pass
        else:
            raise AssertionError('Stale RPCS3 artifact passed provenance validation')
    identity['abi_version'] = 29
    identity_path.write_text(json.dumps(identity))
    try:
        ipa_validator.validate_core_identity(payload, identity_path, expected_core_commit)
    except ipa_validator.ValidationError:
        pass
    else:
        raise AssertionError('Incompatible RPCS3 Core ABI passed validation')

print('PASS: Build306 single launch path and provenance-bound passive Core')
