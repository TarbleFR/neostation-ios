import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS game launch has no App Store-style Open In or Share fallback', () {
    final launch = File('lib/services/game/game_launch_service.dart')
        .readAsStringSync();
    final dartBridge = File(
      'packages/external_folder_access/lib/external_folder_access.dart',
    ).readAsStringSync();
    final nativeBridge = File(
      'packages/external_folder_access/ios/Classes/'
      'ExternalFolderAccessPlugin.swift',
    ).readAsStringSync();

    expect(launch, isNot(contains('openInMenu')));
    expect(launch, isNot(contains('SharePlus')));
    expect(launch, isNot(contains('ResumeNeoStation')));
    expect(
      launch,
      contains('await RetroArchLibraryService.loadCachedLibrary()'),
    );
    expect(dartBridge, isNot(contains('openInMenu')));
    expect(nativeBridge, isNot(contains('UIDocumentInteractionController')));
    expect(nativeBridge, isNot(contains('openInMenu')));
  });
}
