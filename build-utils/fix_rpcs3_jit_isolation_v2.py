#!/usr/bin/env python3
"""Finish RPCS3 JIT isolation and retire obsolete standalone launch tests."""
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one match, found {count}')
    return text.replace(old, new, 1)


# Native RPCS3 bridge: own the host JIT request instead of delegating to Dolphin.
plugin_path = Path('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm')
plugin = plugin_path.read_text()
if '#import "Rpcs3HostJit.h"' not in plugin:
    plugin = replace_once(
        plugin,
        '#import "Rpcs3CoreABI.h"\n',
        '#import "Rpcs3CoreABI.h"\n#import "Rpcs3HostJit.h"\n',
        'RPCS3 host JIT import',
    )
if '[call.method isEqualToString:@"prepareJit"]' not in plugin:
    anchor = '''  if ([call.method isEqualToString:@"initialize"]) {\n'''
    block = '''  if ([call.method isEqualToString:@"prepareJit"]) {
    NSDictionary* args = [call.arguments isKindOfClass:NSDictionary.class]
                             ? call.arguments : @{};
    NSString* pairingPath = [args[@"pairingFilePath"] isKindOfClass:NSString.class]
                                ? args[@"pairingFilePath"] : @"";
    dispatch_async(_runtimeQueue, ^{
      NSDictionary<NSString*, id>* report = RPCS3PrepareHostJit(pairingPath);
      dispatch_async(dispatch_get_main_queue(), ^{ result(report); });
    });
    return;
  }

'''
    plugin = replace_once(plugin, anchor, block + anchor, 'RPCS3 prepareJit method')
plugin_path.write_text(plugin)


# Dart platform bridge: expose the RPCS3-owned helper to the service layer.
bridge_path = Path('packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart')
bridge = bridge_path.read_text()
if 'static Future<Map<String, dynamic>> prepareJit' not in bridge:
    anchor = '''  static Future<Map<String, dynamic>> initialize({\n'''
    block = '''  static Future<Map<String, dynamic>> prepareJit({
    required String pairingFilePath,
  }) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('prepareJit', {
              'pairingFilePath': pairingFilePath,
            }) ??
            const <String, dynamic>{},
      );

'''
    bridge = replace_once(bridge, anchor, block + anchor, 'RPCS3 Dart prepareJit')
bridge_path.write_text(bridge)


# Application service: no dependency on Dolphin is allowed.
service_path = Path('lib/services/rpcs3_internal_service.dart')
service = service_path.read_text()
service = service.replace(
    "import 'package:dolphin_internal_bridge/dolphin_internal_bridge.dart';\n",
    '',
)
old_jit = '''      final jit = await DolphinInternalBridge.prepareHostJit(
        pairingFilePath: pairing.path,
        mode: 'universal',
      );'''
new_jit = '''      final jit = await Rpcs3InternalBridge.prepareJit(
        pairingFilePath: pairing.path,
      );'''
if old_jit in service:
    service = replace_once(service, old_jit, new_jit, 'RPCS3 service JIT route')
if 'DolphinInternalBridge' in service or 'dolphin_internal_bridge' in service:
    raise SystemExit('RPCS3 service still depends on Dolphin after JIT isolation patch')
service_path.write_text(service)


# Old regression tests described the removed standalone IPA handoff. Preserve
# their useful metadata coverage but assert the new direct internal route.
test_replacements = {
    'test/rpcs3_stage3_test.dart': (
        '''    test('RPCS3 launcher uses the stable Universal JIT handoff', () {
      final service = File(
        'lib/services/rpcs3_launch_service.dart',
      ).readAsStringSync();
      expect(service, contains('openJitRequest'));
      expect(service, contains("scriptName: 'universal.js'"));
      expect(service, contains('rpcs3_launch_debug.txt'));
    });''',
        '''    test('RPCS3 launcher boots through the embedded Core', () {
      final service = File(
        'lib/services/rpcs3_launch_service.dart',
      ).readAsStringSync();
      final plugin = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
      ).readAsStringSync();
      expect(service, contains('Rpcs3InternalService.launchTitle'));
      expect(service, isNot(contains('openJitRequest')));
      expect(service, isNot(contains('com.xitrix.RPCS3')));
      expect(plugin, contains('rpcs3_ios_boot_game'));
      expect(plugin, contains('self->_api.boot_game'));
    });''',
    ),
    'test/rpcs3_stage6_test.dart': (
        '''    test('launcher validates serials and uses Universal JIT', () {
      expect(Rpcs3LaunchService.normalizeTitleId('bles00412'), 'BLES00412');
      expect(Rpcs3LaunchService.normalizeTitleId(''), isNull);

      final service = File(
        'lib/services/rpcs3_launch_service.dart',
      ).readAsStringSync();
      expect(service, contains('openJitRequest'));
      expect(service, contains("scriptName: 'universal.js'"));
      expect(service, contains('rpcs3_launch_debug.txt'));
    });''',
        '''    test('launcher validates serials and uses the internal engine', () {
      expect(Rpcs3LaunchService.normalizeTitleId('bles00412'), 'BLES00412');
      expect(Rpcs3LaunchService.normalizeTitleId(''), isNull);

      final service = File(
        'lib/services/rpcs3_launch_service.dart',
      ).readAsStringSync();
      final internal = File(
        'lib/services/rpcs3_internal_service.dart',
      ).readAsStringSync();
      expect(service, contains('Rpcs3InternalService.launchTitle'));
      expect(service, isNot(contains('openJitRequest')));
      expect(internal, contains('Rpcs3InternalBridge.prepareJit'));
      expect(internal, contains("'firmwareRequired'"));
    });''',
    ),
    'test/rpcs3_stage7_test.dart': (
        '''  test('RPCS3 launch uses the basic Universal JIT handoff', () {
    final service = File(
      'lib/services/rpcs3_launch_service.dart',
    ).readAsStringSync();
    expect(service, contains('openJitRequest'));
    expect(service, contains("scriptName: 'universal.js'"));
    expect(service, contains('rpcs3_launch_debug.txt'));
  });''',
        '''  test('RPCS3 launch bypasses the standalone Start screen', () {
    final service = File(
      'lib/services/rpcs3_launch_service.dart',
    ).readAsStringSync();
    final plugin = File(
      'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
    ).readAsStringSync();
    expect(service, contains('Rpcs3InternalService.launchTitle'));
    expect(service, isNot(contains('openJitRequest')));
    expect(plugin, contains('@"launchGame"'));
    expect(plugin, contains('self->_api.boot_game'));
  });''',
    ),
}
for filename, (old, new) in test_replacements.items():
    path = Path(filename)
    text = path.read_text()
    if old in text:
        text = replace_once(text, old, new, filename)
    if 'openJitRequest' in text:
        # Only negative assertions are allowed after migration.
        positive = "expect(service, contains('openJitRequest'))"
        if positive in text:
            raise SystemExit(f'{filename}: obsolete external JIT assertion remains')
    path.write_text(text)

print('RPCS3 JIT is isolated and obsolete standalone launch tests are updated.')
