#!/usr/bin/env python3
from pathlib import Path
import sys

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
build = (root / 'build-utils/build_rpcs3_embedded_core.sh').read_text()
assert build.count('patch_rpcs3_savestate_stability.py') == 2
assert 'rpcs3_savestate_native_test.py' in build
assert build.count('patch_rpcs3_armsx3_performance.py') == 2
assert build.count('patch_rpcs3_serial_profiles.py') == 2
print('PASS: native savestate completion UI, 12 languages, detach guards, core wiring')
