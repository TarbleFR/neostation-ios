import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/launcher_service.dart';

/// Pins the Linux discovery hints all the way through to the launch command.
///
/// [LauncherService] copies a fixed set of keys out of the platform block, so a
/// hint it does not name is dropped silently — the launch then falls back to
/// the bare `executable`, which is exactly the failure discovery exists to
/// prevent. Reading the real `assets/systems/gc.json` also keeps the JSON's key
/// spelling and this code honest about each other.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!Platform.isLinux) {
    test('Linux launcher hints are exercised only on Linux hosts', () {
      expect(Platform.isLinux, isFalse);
    });
    return;
  }

  final service = LauncherService.instance;

  final system = SystemModel(
    id: 'gc',
    folderName: 'gc',
    realName: 'Nintendo GameCube',
    iconImage: '',
    color: '#7E57C2',
  );
  const game = GameModel(
    romname: 'game.rvz',
    realname: 'Game',
    name: 'Game',
    year: '2003',
    developer: '',
    publisher: '',
    genre: '',
    players: '1',
    rating: 0,
    romPath: '/roms/gc/game.rvz',
    systemFolderName: 'gc',
  );

  setUpAll(() async {
    expect(await service.loadSystemConfig('gc.json'), isTrue);
  });

  test('carries flatpak and emudeck_launcher into the launch command', () {
    final command = service.getLaunchCommand(
      system,
      game,
      'gc.org.dolphinemu.dolphinemu',
    );

    expect(command['executable'], 'dolphin');
    expect(command['flatpak'], 'org.DolphinEmu.dolphin-emu');
    expect(command['emudeck_launcher'], 'dolphin-emu.sh');
  });

  test('passes the ROM to Dolphin instead of opening its game list', () {
    final command = service.getLaunchCommand(
      system,
      game,
      'gc.org.dolphinemu.dolphinemu',
    );

    expect(command['args'], isNotNull);
    expect(command['args'].toString(), contains('/roms/gc/game.rvz'));
  });

  test('resolves a RetroArch core entry with its hints', () {
    final command = service.getLaunchCommand(system, game, 'gc.ra.dolphin');

    expect(command['executable'], 'retroarch');
    expect(command['flatpak'], 'org.libretro.RetroArch');
    expect(command['emudeck_launcher'], 'retroarch.sh');
    expect(command['args'].toString(), contains('dolphin_libretro.so'));
  });

  group('getLinuxDiscoveryHints', () {
    test('exposes the hints an install check needs', () {
      final hints = service.getLinuxDiscoveryHints(
        'gc',
        'gc.org.dolphinemu.dolphinemu',
      );

      expect(hints, isNotNull);
      expect(hints!['executable'], 'dolphin');
      expect(hints['flatpak'], 'org.DolphinEmu.dolphin-emu');
      expect(hints['emudeck_launcher'], 'dolphin-emu.sh');
    });

    test('returns null for an emulator the config does not define', () {
      expect(service.getLinuxDiscoveryHints('gc', 'gc.does.not.exist'), isNull);
    });

    test('returns null for a system that was never loaded', () {
      expect(service.getLinuxDiscoveryHints('not-a-system', 'x'), isNull);
    });
  });
}
