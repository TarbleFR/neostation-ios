import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ARMSX2-owned PS2 paths cannot fall through to RetroArch', () {
    final launch = File(
      'lib/services/game/game_launch_service.dart',
    ).readAsStringSync();

    expect(
      launch,
      contains('final isArmsx2OwnedRom = Armsx2FolderService.ownsRomPath'),
    );
    expect(launch, contains('if (isArmsx2OwnedRom || isArmsx2VirtualRom)'));
    expect(launch, contains("'Could not launch this PS2 game in ARMSX2.'"));

    final ownershipIndex = launch.indexOf('final isArmsx2OwnedRom');
    final retroFallbackIndex = launch.indexOf(
      'RetroArchLibraryService.launchGameByRomPath',
      ownershipIndex,
    );
    expect(ownershipIndex, greaterThanOrEqualTo(0));
    expect(retroFallbackIndex, greaterThan(ownershipIndex));
  });

  test('physical ARMSX2 launch no longer requires exported library cache', () {
    final service = File(
      'lib/services/armsx2_library_service.dart',
    ).readAsStringSync();

    expect(service, contains('ownsLinkedPhysicalRom'));
    expect(service, contains('_launchLinkedPhysicalRom(romPath)'));
    expect(service, contains('Uri.encodeComponent(fileName)'));
    expect(service, isNot(contains('requestLibrarySync()')));
    expect(service, isNot(contains('handleIncomingUri(Uri uri)')));
    expect(service, isNot(contains('_importIntoNeoStation')));
    expect(service, isNot(contains('hasSyncedLibrary')));
    expect(service, contains('cleanupLegacyExportArtifacts'));
    expect(
      service,
      contains("Uri.parse('armsx2://launch?game=\$encodedFileName')"),
    );
    expect(
      service,
      isNot(contains("queryParameters: {'game': fileName}")),
    );
  });

  test('ARMSX2 no longer registers exported-library callbacks at startup', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    expect(mainSource, isNot(contains('Armsx2LibraryService.loadCachedLibrary')));
    expect(
      mainSource,
      isNot(contains('Armsx2LibraryService.handleIncomingUri')),
    );
    expect(
      mainSource,
      contains('Armsx2LibraryService.cleanupLegacyExportArtifacts'),
    );
  });

  test('PS2 cloud adapters preserve separate native emulator roots', () {
    final resolver = File('lib/services/cloud_saves/save_source_registry.dart').readAsStringSync();
    expect(resolver, contains('ConfigService.linkedArmsx2FolderPath'));
    expect(resolver, contains("_unit('ARMSX2', 'PlayStation 2'"));
    expect(resolver, contains("_unit('RetroArch',"));
    expect(resolver, contains('config.savefileDirectory'));
    expect(resolver, contains('config.savestateDirectory'));
    expect(resolver, isNot(contains('linkedArmsx2SaveFolderPath')));
  });

  test('ARMSX2 has one ConfigService root and no save-only bookmark', () {
    final config = File('lib/services/config_service.dart').readAsStringSync();
    expect(config, contains('linkedArmsx2FolderPath'));
    expect(config, contains('linkedArmsx2GameFolderPath'));
    expect(config, isNot(contains('linkedArmsx2SaveFolderPath')));
  });
}
