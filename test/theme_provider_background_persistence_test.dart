import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:path/path.dart' as path;

void main() {
  group('ThemeProvider custom background persistence', () {
    test('recovers background after the iOS container root changes', () async {
      final temp = await Directory.systemTemp.createTemp(
        'neostation-background-container-move',
      );
      addTearDown(() => temp.delete(recursive: true));

      final currentUserData = Directory(
        path.join(temp.path, 'new-container', 'Documents', 'user-data'),
      );
      final backgroundDir = Directory(
        path.join(currentUserData.path, 'custom_background'),
      );
      await backgroundDir.create(recursive: true);
      final currentBackground = File(
        path.join(backgroundDir.path, 'background.png'),
      );
      await currentBackground.writeAsBytes(const <int>[1, 2, 3, 4]);

      final staleAbsolutePreference = path.join(
        temp.path,
        'old-container',
        'Documents',
        'user-data',
        'custom_background',
        'background.png',
      );

      final resolved =
          await ThemeProvider.resolvePersistedCustomBackgroundForTesting(
            userDataPath: currentUserData.path,
            savedPreference: staleAbsolutePreference,
          );

      expect(path.normalize(resolved!), path.normalize(currentBackground.path));
    });

    test(
      'resolves the new container-independent basename preference',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'neostation-background-relative-pref',
        );
        addTearDown(() => temp.delete(recursive: true));

        final userData = Directory(path.join(temp.path, 'user-data'));
        final backgroundDir = Directory(
          path.join(userData.path, 'custom_background'),
        );
        await backgroundDir.create(recursive: true);
        final currentBackground = File(
          path.join(backgroundDir.path, 'background.mp4'),
        );
        await currentBackground.writeAsBytes(const <int>[5, 6, 7, 8]);

        final resolved =
            await ThemeProvider.resolvePersistedCustomBackgroundForTesting(
              userDataPath: userData.path,
              savedPreference: 'background.mp4',
            );

        expect(
          path.normalize(resolved!),
          path.normalize(currentBackground.path),
        );
      },
    );

    test(
      'migrates a still-readable legacy file into current user data',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'neostation-background-legacy-migrate',
        );
        addTearDown(() => temp.delete(recursive: true));

        final legacyDir = Directory(path.join(temp.path, 'legacy-support'));
        await legacyDir.create(recursive: true);
        final legacy = File(path.join(legacyDir.path, 'wallpaper.jpg'));
        await legacy.writeAsBytes(const <int>[9, 10, 11]);

        final userData = Directory(path.join(temp.path, 'current-user-data'));
        final resolved =
            await ThemeProvider.resolvePersistedCustomBackgroundForTesting(
              userDataPath: userData.path,
              savedPreference: legacy.path,
            );

        final expected = path.join(
          userData.path,
          'custom_background',
          'background.jpg',
        );
        expect(path.normalize(resolved!), path.normalize(expected));
        expect(await File(expected).readAsBytes(), const <int>[9, 10, 11]);
        expect(await legacy.exists(), isTrue);
      },
    );

    test('does not reactivate an unsupported leftover file', () async {
      final temp = await Directory.systemTemp.createTemp(
        'neostation-background-unsupported',
      );
      addTearDown(() => temp.delete(recursive: true));

      final userData = Directory(path.join(temp.path, 'user-data'));
      final backgroundDir = Directory(
        path.join(userData.path, 'custom_background'),
      );
      await backgroundDir.create(recursive: true);
      await File(path.join(backgroundDir.path, 'background.txt'))
          .writeAsString('not a supported background');

      final resolved =
          await ThemeProvider.resolvePersistedCustomBackgroundForTesting(
            userDataPath: userData.path,
            savedPreference: 'background.txt',
          );

      expect(resolved, isNull);
    });
  });
}
