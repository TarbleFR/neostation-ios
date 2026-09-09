#!/usr/bin/env python3
"""Normalize remaining RPCS3 migration inputs before final validation.

The migration script is already surgical on this branch. This helper now only
normalizes APIs/tests that may still reflect the removed standalone RPCS3 IPA.
It never reads or modifies Dolphin source.
"""
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one match, found {count}')
    return text.replace(old, new, 1)


# The pinned file_picker build uses static methods rather than FilePicker.platform.
service = Path('lib/services/rpcs3_internal_service.dart')
service_text = service.read_text()
service_text = service_text.replace(
    'FilePicker.platform.pickFiles(',
    'FilePicker.pickFiles(',
)
service_text = service_text.replace(
    'FilePicker.platform.getDirectoryPath(',
    'FilePicker.getDirectoryPath(',
)
if 'FilePicker.platform' in service_text:
    raise SystemExit('Unsupported FilePicker.platform API remains in RPCS3 service')
if 'DolphinInternalBridge' in service_text or 'dolphin_internal_bridge' in service_text:
    raise SystemExit('RPCS3 internal service must not depend on Dolphin')
service.write_text(service_text)

# Retire test expectations for the old standalone RPCS3 IPA handoff. Each
# replacement is idempotent: already-migrated tests are accepted as-is.
replacements = {
    'test/rpcs3_stage3_test.dart': (
        """    test('RPCS3 launcher uses the stable Universal JIT handoff', () {
      final service = File(
        'lib/services/rpcs3_launch_service.dart',
      ).readAsStringSync();
      expect(service, contains('openJitRequest'));
      expect(service, contains(\"scriptName: 'universal.js'\"));
      expect(service, contains('rpcs3_launch_debug.txt'));
    });""",
        """    test('RPCS3 launcher boots through the embedded Core', () {
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
    });""",
        'Rpcs3InternalService.launchTitle',
    ),
    'test/rpcs3_stage6_test.dart': (
        """    test('launcher validates serials and uses Universal JIT', () {
      expect(Rpcs3LaunchService.normalizeTitleId('bles00412'), 'BLES00412');
      expect(Rpcs3LaunchService.normalizeTitleId(''), isNull);

      final service = File(
        'lib/services/rpcs3_launch_service.dart',
      ).readAsStringSync();
      expect(service, contains('openJitRequest'));
      expect(service, contains(\"scriptName: 'universal.js'\"));
      expect(service, contains('rpcs3_launch_debug.txt'));
    });""",
        """    test('launcher validates serials and uses the internal engine', () {
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
      expect(internal, contains(\"'firmwareRequired'\"));
    });""",
        'Rpcs3InternalBridge.prepareJit',
    ),
    'test/rpcs3_stage7_test.dart': (
        """  test('RPCS3 launch uses the basic Universal JIT handoff', () {
    final service = File(
      'lib/services/rpcs3_launch_service.dart',
    ).readAsStringSync();
    expect(service, contains('openJitRequest'));
    expect(service, contains(\"scriptName: 'universal.js'\"));
    expect(service, contains('rpcs3_launch_debug.txt'));
  });""",
        """  test('RPCS3 launch bypasses the standalone Start screen', () {
    final service = File(
      'lib/services/rpcs3_launch_service.dart',
    ).readAsStringSync();
    final plugin = File(
      'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
    ).readAsStringSync();
    expect(service, contains('Rpcs3InternalService.launchTitle'));
    expect(service, isNot(contains('openJitRequest')));
    expect(plugin, contains('@\"launchGame\"'));
    expect(plugin, contains('self->_api.boot_game'));
  });""",
        'self->_api.boot_game',
    ),
}
for filename, (old, new, migrated_marker) in replacements.items():
    path = Path(filename)
    body = path.read_text()
    if old in body:
        body = replace_once(body, old, new, filename)
    elif migrated_marker not in body:
        raise SystemExit(f'{filename}: neither old nor migrated RPCS3 contract found')
    path.write_text(body)

print('RPCS3 file-picker and internal-engine test contracts are normalized.')
