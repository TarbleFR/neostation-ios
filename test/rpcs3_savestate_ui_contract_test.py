#!/usr/bin/env python3
from pathlib import Path
import sys
import re

root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
classes = root / 'packages/rpcs3_internal_bridge/ios/Classes'
plugin = (classes / 'Rpcs3InternalBridgePlugin.mm').read_text()
abi = (classes / 'Rpcs3CoreABI.h').read_text()
localization = (classes / 'RPCS3InGameLocalization.mm').read_text()
assert 'LOAD("neostation_rpcs3_ios_get_savestate_status", get_savestate_status)' in plugin
assert '(*get_savestate_status)(uint32_t*, char*, size_t)' in abi
assert 'status == 0 && phase == 4' in plugin
assert 'phase >= 1 && phase <= 3' in plugin
assert 'alert.modalInPresentation = YES' in plugin
assert 'savestate_complete' in plugin
save = plugin[plugin.index('- (void)saveCurrentStateAtSlot:'):plugin.index('- (void)confirmOverwriteSlot:')]
assert 'showMessage:' not in save, 'Do not claim completion when the command was merely accepted'
assert 'pollSavestateAlert:' in save
for method, end, guard in [
    ('- (void)stopAndDismiss:', '\n@end', 'if (!ok)'),
    ('if ([call.method isEqualToString:@"shutdown"])', 'if ([call.method isEqualToString:@"firmwareVersion"])', 'if (stopStatus != 0)'),
]:
    body = plugin[plugin.index(method):]
    body = body[:body.index(end)]
    assert body.index(guard) < body.index('set_display_surface(NULL)')
    assert 'return;' in body[body.index(guard):body.index('set_display_surface(NULL)')]
for key in ('stateDone', 'stateFailed'):
    assert localization.count(f'@"{key}":') == 12
workflow = (root / '.github/workflows/build-ipa-once.yml').read_text()
build = (root / 'build-utils/build_rpcs3_embedded_core.sh').read_text()
assert workflow.count('patch_rpcs3_savestate_ui.py') == 2
assert build.count('patch_rpcs3_savestate_stability.py') == 2
assert 'rpcs3_savestate_native_test.py' in build
version = re.search(r"BUILD_NUMBER: '([0-9]+)'", workflow)
assert version, 'Workflow must declare an explicit build number'
if f'BUILD_NUMBER={version.group(1)}' not in build:
    # Retain the historic patch anchor while admitting the rollback's host
    # version. This does not claim that its unchanged core was recompiled.
    assert (version.group(1) in ('267', '268') or version.group(1) == '271') and 'BUILD_NUMBER=266' in build
    reuse = (root / 'build-utils/reuse_build266_rpcs3_for267.py').read_text()
    assert 'python3 build-utils/reuse_build266_rpcs3_for267.py build/reference266' in workflow
    assert 'run-id: 35140629752' in workflow
    assert 'validate_rpcs3_embedded_core.py "$CORE"' in workflow
    assert 'changed - ALLOWED' in reuse
    assert "hashlib.sha256(data).hexdigest() != CORE_SHA256" in reuse
    assert "CORE_SHA256 = 'dba1bb3bf8847faf3e378c1815ffe895521d8d6404e468bb6a2eee5fa8cb4ddd'" in reuse
    if version.group(1) == '268':
        assert 'python3 test/rpcs3_build268_tunnel_test.py' in workflow
        assert 'local_jit_debugger_lease_test.dart' in workflow
    if version.group(1) == '271':
        assert 'python3 test/vpn271_baseline_test.py' in workflow
        assert 'python3 test/vpn_build271_test.py' in workflow
        assert 'validate_build271_identity.py' in workflow
assert build.count('patch_rpcs3_armsx3_performance.py') == 2
assert build.count('patch_rpcs3_serial_profiles.py') == 2
assert workflow.count('patch_rpcs3_performance_telemetry.py') >= 2
print('PASS: native savestate completion UI, 12 languages, detach guards, CI wiring')
