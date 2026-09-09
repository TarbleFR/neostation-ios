#!/usr/bin/env python3
"""Repair the one-shot RPCS3 migration before applying it.

The previous migration used overly broad replacement ranges and some regression
tests still described the removed standalone RPCS3 IPA handoff. This script
repairs those migration-only issues without modifying any Dolphin source.
"""
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one match, found {count}')
    return text.replace(old, new, 1)


finalize = Path('build-utils/finalize_rpcs3_internal_v1.py')
text = finalize.read_text()

old = """    '  static Future<String?> _resolveLinkedDataRoot() async {',
    '  static Future<bool> _canReadDataRoot(String dataRoot) async {',
"""
new = """    '  static Future<String?> _resolveLinkedDataRoot() async {',
    '  static Future<void> _replaceCache(List<Rpcs3LibraryGame> games) async {',
"""
if old not in text:
    raise SystemExit('RPCS3 library resolver migration anchor not found')
text = text.replace(old, new, 1)

old = """        '  List<Widget> _iosEmulatorCards(ThemeData theme) {',
        'RPCS3 directory actions',
"""
new = """        '',
        'RPCS3 directory actions',
"""
if old not in text:
    raise SystemExit('RPCS3 directory-action migration anchor not found')
text = text.replace(old, new, 1)

old = """        '  Widget _buildIOSArmsx2Section(ThemeData theme) {',
        'RPCS3 directory card',
"""
new = """        '',
        'RPCS3 directory card',
"""
if old not in text:
    raise SystemExit('RPCS3 directory-card migration anchor not found')
text = text.replace(old, new, 1)
finalize.write_text(text)

# The project uses the static file_picker API (the pinned beta removed
# FilePicker.platform). Keep RPCS3 consistent with every other iOS importer.
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

# The following tests predate the in-process Core and expected NeoStation to
# launch the standalone RPCS3 IPA through openJitRequest. Keep their useful
# metadata coverage while asserting direct embedded-Core boot instead.
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
    ),
}
for filename, (old, new) in replacements.items():
    path = Path(filename)
    body = path.read_text()
    if old not in body:
        raise SystemExit(f'{filename}: obsolete standalone test block not found')
    path.write_text(replace_once(body, old, new, filename))

print('RPCS3 migration, file picker API, and standalone test expectations repaired.')
