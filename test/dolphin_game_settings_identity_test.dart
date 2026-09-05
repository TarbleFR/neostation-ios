import 'dart:convert';
import 'dart:io';

import 'package:dolphin_internal_bridge/dolphin_playlist_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Embedded DolphiniOS identity in game settings', () {
    for (final entry in const {
      'gc': 'gc',
      'GameCube': 'gc',
      'Nintendo GameCube': 'gc',
      'ngc': 'gc',
      'wii': 'wii',
      'Nintendo Wii': 'wii',
    }.entries) {
      test('recognizes the ${entry.key} playlist', () {
        expect(
          DolphinPlaylistIdentity.forGameSettings(
            systemFolderName: entry.key,
            isAllMode: false,
          ),
          entry.value,
        );
      });
    }

    test('normalizes case and whitespace without changing stored names', () {
      const folder = '  NINTENDO GAMECUBE  ';
      expect(
        DolphinPlaylistIdentity.forGameSettings(
          systemFolderName: folder,
          isAllMode: false,
        ),
        'gc',
      );
      expect(folder, '  NINTENDO GAMECUBE  ');
    });

    for (final virtualFolder in ['all', 'favorites']) {
      test('uses the GameCube game identity in $virtualFolder', () {
        expect(
          DolphinPlaylistIdentity.forGameSettings(
            systemFolderName: virtualFolder,
            gameSystemFolderName: 'GameCube',
            isAllMode: true,
          ),
          'gc',
        );
      });

      test('does not invent a game identity in $virtualFolder', () {
        expect(
          DolphinPlaylistIdentity.forGameSettings(
            systemFolderName: virtualFolder,
            isAllMode: true,
          ),
          isNull,
        );
      });
    }

    test('a virtual view never overrides a different game system', () {
      expect(
        DolphinPlaylistIdentity.forGameSettings(
          systemFolderName: 'gc',
          gameSystemFolderName: 'ps2',
          isAllMode: true,
        ),
        isNull,
      );
    });

    test('normal playlists keep their own system identity', () {
      expect(
        DolphinPlaylistIdentity.forGameSettings(
          systemFolderName: 'ps3',
          gameSystemFolderName: 'gc',
          isAllMode: false,
        ),
        isNull,
      );
    });

    test('covers the aliases declared by GameCube and Wii assets', () {
      for (final system in ['gc', 'wii']) {
        final definition = jsonDecode(
          File('assets/systems/$system.json').readAsStringSync(),
        ) as Map<String, dynamic>;
        final data = definition['system'] as Map<String, dynamic>;
        for (final folder in data['folders'] as List<dynamic>) {
          expect(
            DolphinPlaylistIdentity.forGameSettings(
              systemFolderName: folder as String,
              isAllMode: false,
            ),
            system,
            reason: 'Missing the declared $system alias $folder',
          );
        }
      }
    });

    test('does not capture any other configured system playlist', () {
      final definitions = Directory('assets/systems')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'));
      var checkedSystems = 0;
      for (final file in definitions) {
        final definition = jsonDecode(file.readAsStringSync());
        if (definition is! Map<String, dynamic>) continue;
        final data = definition['system'];
        if (data is! Map<String, dynamic>) continue;
        if (data['id'] == 'gc' || data['id'] == 'wii') continue;
        final folders = data['folders'];
        if (folders is! List) continue;
        checkedSystems++;
        for (final folder in folders.whereType<String>()) {
          expect(
            DolphinPlaylistIdentity.forGameSettings(
              systemFolderName: folder,
              isAllMode: false,
            ),
            isNull,
            reason: '${file.path}: Dolphin must not own $folder',
          );
        }
      }
      expect(checkedSystems, greaterThan(0));
    });

    test('does not infer a console from an extension or partial name', () {
      for (final folder in [
        '', 'all', 'favorites', 'wiiu', 'Wii U', 'ps1', 'ps2', 'ps3',
        'switch', '3ds', 'iso', 'game.iso', 'gc-backup', 'gc/game.iso',
      ]) {
        expect(
          DolphinPlaylistIdentity.forGameSettings(
            systemFolderName: folder,
            isAllMode: false,
          ),
          isNull,
          reason: 'Unexpected Dolphin identity for $folder',
        );
      }
    });
  });
}
