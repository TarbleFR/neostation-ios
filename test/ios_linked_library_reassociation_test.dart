import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';

void main() {
  test('moves NeoStation association to a newly resolved linked source', () {
    expect(
      replacedRomFolderPaths(
        const ['/roms', '/manic-old-root'],
        '/manic-old-root',
        '/manic-new-root',
      ),
      const ['/roms', '/manic-new-root'],
    );
  });

  test('moves RetroArch association between resolved TestFlight roots', () {
    expect(
      replacedRomFolderPaths(
        const ['/roms', '/retroarch-old-root'],
        '/retroarch-old-root',
        '/retroarch-new-root',
      ),
      const ['/roms', '/retroarch-new-root'],
    );
  });

  test('selecting the same linked folder keeps one source', () {
    expect(
      replacedRomFolderPaths(
        const ['/roms', '/manic-new-root'],
        '/manic-new-root',
        '/manic-new-root',
      ),
      const ['/roms', '/manic-new-root'],
    );
  });

  test('a replacement can proceed when all source slots are occupied', () {
    expect(
      replacedRomFolderPaths(
        const ['/one', '/two', '/three', '/four', '/manic-old-root'],
        '/manic-old-root',
        '/manic-new-root',
      ),
      const ['/one', '/two', '/three', '/four', '/manic-new-root'],
    );
  });

  test('onboarding activates the iOS bookmark before scanning it', () {
    final folderAccess = File(
      'packages/external_folder_access/lib/external_folder_access.dart',
    ).readAsStringSync();
    final wizard = File('lib/widgets/setup_wizard.dart').readAsStringSync();

    final helperStart = folderAccess.indexOf(
      'static Future<String?> pickAndActivateFolder',
    );
    final helperEnd = folderAccess.indexOf(
      '/// Resolves the folder previously bookmarked',
      helperStart,
    );
    expect(helperStart, greaterThanOrEqualTo(0));
    expect(helperEnd, greaterThan(helperStart));

    final helper = folderAccess.substring(helperStart, helperEnd);
    expect(
      helper.indexOf('pickAndBookmarkFolder'),
      lessThan(helper.indexOf('resolveBookmarkedFolder')),
    );
    final selectionStart = wizard.indexOf('Future<void> _selectFolder({');
    final selectionEnd = wizard.indexOf(
      'Future<void> _ensureLinkedFolderIsReadable',
      selectionStart,
    );
    expect(selectionStart, greaterThanOrEqualTo(0));
    expect(selectionEnd, greaterThan(selectionStart));
    final selection = wizard.substring(selectionStart, selectionEnd);
    final pickIndex = selection.indexOf('pickAndActivateFolder(');
    final readIndex = selection.indexOf(
      'await _ensureLinkedFolderIsReadable(linked)',
    );
    final scanIndex = selection.indexOf(
      'if (mounted) await configProvider.scanSystems()',
    );
    expect(pickIndex, greaterThanOrEqualTo(0));
    expect(readIndex, greaterThan(pickIndex));
    expect(scanIndex, greaterThan(readIndex));
    expect(wizard, contains('consumeStartupScan()'));
  });

  test('large Manic EMU ROM launch uses bounded native streaming', () {
    final service = File('lib/services/manic_emu_launch_service.dart')
        .readAsStringSync();
    final native = File(
      'packages/external_folder_access/ios/Classes/'
      'ExternalFolderAccessPlugin.swift',
    ).readAsStringSync();

    expect(service, contains('ExternalFolderAccess.sha256File('));
    expect(service, contains('.timeout(_hashTimeout)'));
    expect(service, contains('ExternalFolderAccess.openRawUrl('));
    expect(service, contains('return opened;'));
    expect(native, contains('while autoreleasepool(invoking: {'));
    expect(native, contains('readData(ofLength: 1024 * 1024)'));
  });
}
