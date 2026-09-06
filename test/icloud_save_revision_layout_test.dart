import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/cloud_saves/save_revision.dart';

void main() {
  String directory(String emulator, String system) => SaveRevision.directoryFor(
        emulator,
        system,
        'Shared',
        'Saves',
        '$emulator/$system/Shared/Saves/sample',
      );

  test('built-in emulator revisions stay under the folders created at authorization', () {
    expect(directory('DolphiniOS', 'GameCube'), startsWith('DolphiniOS/GameCube/'));
    expect(directory('DolphiniOS', 'Wii'), startsWith('DolphiniOS/Wii/'));
    expect(directory('ARMSX2', 'PlayStation 2'), startsWith('ARMSX2/PS2/'));
    expect(directory('MeloNX', 'Switch'), startsWith('MeloNX/Switch/'));
    expect(directory('RPCS3', 'PlayStation 3'), startsWith('RPCS3/PS3/'));
    expect(directory('RetroArch', 'Shared library'), startsWith('RetroArch/Shared library/'));
  });

  test('old Build 208 console labels remain readable after canonicalization', () {
    const hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const unit = 'ARMSX2/PlayStation 2/Shared/Saves/sample';
    final suffix = SaveRevision.directoryFor('ARMSX2', 'PlayStation 2', 'Shared', 'Saves', unit)
        .split('/')
        .last;
    final revision = SaveRevision.fromJson({
      'schema': 1,
      'unit': unit,
      'emulator': 'ARMSX2',
      'system': 'PlayStation 2',
      'owner': 'Shared',
      'title': 'Shared save',
      'kind': 'Saves',
      'format': 'native-v1',
      'contentHash': hash,
      'payloadHash': hash,
      'size': 1,
      'modified': DateTime.utc(2026, 9, 6).toIso8601String(),
      'directory': 'ARMSX2/PlayStation 2/Shared/Saves/$suffix',
    });
    expect(revision.relativeDirectory, startsWith('ARMSX2/PlayStation 2/'));
  });
}
