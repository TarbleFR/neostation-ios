import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_appstore_launch_target.dart';

void main() {
  group('RetroArch App Store archive launch target', () {
    test('uses the archive container for a 32X playlist entry', () {
      const playlistPath =
          '~/Documents/RetroArch/Bibliothèques /32x/'
          'Virtua Racing Deluxe (Europe).zip#'
          'Virtua Racing Deluxe (Europe).32x';

      final mapping =
          RetroArchAppStoreLaunchTarget.mappingFromPlaylistPath(playlistPath);

      expect(mapping, isNotNull);
      expect(
        mapping!.$1,
        '~/Documents/RetroArch/Bibliothèques /32x/'
        'Virtua Racing Deluxe (Europe).zip',
      );
      expect(mapping.$2, 'Virtua Racing Deluxe (Europe).32x');

      final launchTarget = RetroArchAppStoreLaunchTarget.select(
        launchId: mapping.$2,
        fullPlaylistPath: playlistPath,
      );

      expect(launchTarget, mapping.$1);
      // The literal space after "Bibliothèques" is part of the folder name
      // supplied by RetroArch and must never be trimmed away.
      expect(launchTarget, contains('Bibliothèques /32x/'));
    });

    test('builds one encoded URL segment and round-trips the RetroArch path', () {
      const target =
          "~/Documents/RetroArch/Bibliothèques /32x/"
          "Parasquad ~ Zaxxon's Motherbase 2000 (Japan, USA).zip";

      final uri = RetroArchAppStoreLaunchTarget.buildUri(target);

      expect(uri.scheme, 'retroarch');
      expect(uri.host, 'game');
      expect(uri.pathSegments, <String>[target]);
      expect(uri.toString(), contains('%2F'));
      expect(uri.toString(), contains('%20'));
      expect(uri.toString(), isNot(contains('#')));
    });

    test('keeps ordinary non-archive playlist launches unchanged', () {
      const playlistPath = '~/Documents/RetroArch/roms/Sonic.32x';
      final mapping =
          RetroArchAppStoreLaunchTarget.mappingFromPlaylistPath(playlistPath);

      expect(mapping, isNotNull);
      expect(mapping!.$1, playlistPath);
      expect(mapping.$2, 'Sonic.32x');
      expect(
        RetroArchAppStoreLaunchTarget.select(
          launchId: mapping.$2,
          fullPlaylistPath: playlistPath,
        ),
        'Sonic.32x',
      );
    });

    test('does not treat an unrelated hash as an archive delimiter', () {
      const playlistPath = '~/Documents/RetroArch/roms/Game#RevA.32x';
      final mapping =
          RetroArchAppStoreLaunchTarget.mappingFromPlaylistPath(playlistPath);

      expect(mapping, isNotNull);
      expect(mapping!.$1, playlistPath);
      expect(mapping.$2, 'Game#RevA.32x');
      expect(
        RetroArchAppStoreLaunchTarget.archiveContainerPath(playlistPath),
        isNull,
      );
    });
  });
}
