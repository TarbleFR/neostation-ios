#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
service = (ROOT / 'lib/services/rpcs3_internal_service.dart').read_text()
launcher = (ROOT / 'lib/services/rpcs3_launch_service.dart').read_text()
bridge = (ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
dart_bridge = (ROOT / 'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart').read_text()
workflow = (ROOT / '.github/workflows/ios-ci.yml').read_text()
validator = (ROOT / 'build-utils/validate_rpcs3_ipa.py').read_text()

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

proven = 'dba1bb3bf8847faf3e378c1815ffe895521d8d6404e468bb6a2eee5fa8cb4ddd'
assert proven in workflow
assert proven in validator
assert 'RPCS3Core-' + '${{ env.RPCS3_CORE_HOST_SHA }}' not in workflow
assert 'patch_rpcs3_build301_passive_dlopen.py' not in workflow
assert 'patch_rpcs3_build303_restartable_lifecycle.py' not in workflow

print('PASS: RPCS3 Build304 uses one linear launch path and the proven Build266 Core')
