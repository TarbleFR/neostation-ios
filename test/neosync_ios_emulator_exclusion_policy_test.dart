import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/services/dolphin_neosync_store.dart';
import 'package:neostation/services/neosync/neo_sync_save_policy.dart';

void main() {
  const armsx2Root = '/private/var/mobile/Containers/Shared/AppGroup/ARMSX2';

  bool excludesGame({
    required String systemFolder,
    required String emulatorName,
    required String romPath,
    String? titleId,
    bool isIOS = true,
  }) =>
      NeoSyncSavePolicy.isIosEmulatorExcluded(
        systemFolder: systemFolder,
        emulatorName: emulatorName,
        romPath: romPath,
        titleId: titleId,
        armsx2Root: armsx2Root,
        isIOS: isIOS,
      );

  NeoSyncFile canonicalCloudFile(String key) => NeoSyncFile.fromJson({
        'id': key.hashCode.toString(),
        'file_name': key,
        'file_path': '/account/$key',
        'file_size': 4,
        'game_name': 'Fixture',
      });

  NeoSyncFile structuredCloudFile({
    required String system,
    required String emulator,
    required String nativePath,
    String type = 'save',
  }) =>
      NeoSyncFile.fromJson({
        'id': '$system-$emulator-$nativePath'.hashCode.toString(),
        'file_path': nativePath,
        'file_size': 4,
        'game_name': 'Fixture',
        'system_name': system,
        'emulator': emulator,
        'type': type,
      });

  group('iOS game routing exclusion', () {
    test('RPCS3 is excluded by virtual URI or selected emulator', () {
      expect(
        excludesGame(
          systemFolder: 'ps3',
          emulatorName: '',
          romPath: 'rpcs3-library://game?title-id=BLES00412',
        ),
        isTrue,
      );
      expect(
        excludesGame(
          systemFolder: 'ps3',
          emulatorName: 'ps3.rpcs3',
          romPath: '/Games/PlayStation 3/BLES00412.iso',
        ),
        isTrue,
      );
      expect(
        excludesGame(
          systemFolder: 'ps3',
          emulatorName: 'ps3.ios.retroarch',
          romPath: '/Games/PlayStation 3/BLES00412.iso',
          titleId: 'BLES00412',
        ),
        isTrue,
        reason: 'the launcher routes every PS3 title ID to RPCS3 first',
      );
    });

    test('ARMSX2 is excluded by virtual URI or linked-root ownership', () {
      expect(
        excludesGame(
          systemFolder: 'ps2',
          emulatorName: '',
          romPath: 'armsx2://launch?game=Le%20Hobbit.iso',
        ),
        isTrue,
      );
      expect(
        excludesGame(
          systemFolder: 'ps2',
          emulatorName: '',
          romPath: '$armsx2Root/iso/Le Hobbit.iso',
        ),
        isTrue,
      );
      expect(
        excludesGame(
          systemFolder: 'ps2',
          emulatorName: 'ps2.ios.retroarch',
          romPath: '$armsx2Root/iso/Le Hobbit.iso',
        ),
        isTrue,
        reason: 'the launcher gives the linked ARMSX2 root hard ownership',
      );
    });

    test('MeloNX is excluded by virtual URI or selected emulator', () {
      expect(
        excludesGame(
          systemFolder: 'switch',
          emulatorName: '',
          romPath: 'melonx://game?titleId=01006A800016E000',
        ),
        isTrue,
      );
      expect(
        excludesGame(
          systemFolder: 'switch',
          emulatorName: 'switch.ios.melonx',
          romPath: '/Games/Switch/Smash.xci',
        ),
        isTrue,
      );
    });

    test('native GameCube and Wii routes are excluded from NeoSync', () {
      for (final system in ['gc', 'wii']) {
        expect(
          excludesGame(
            systemFolder: system,
            emulatorName: '$system.ios.dolphinios',
            romPath: '/NeoStation/Dolphin/Library/$system/Game.rvz',
          ),
          isTrue,
          reason: system,
        );
      }
    });

    test('non-iOS and RetroArch-owned games remain eligible', () {
      expect(
        excludesGame(
          systemFolder: 'ps3',
          emulatorName: 'ps3.rpcs3',
          romPath: 'rpcs3-library://game?title-id=BLES00412',
          isIOS: false,
        ),
        isFalse,
      );
      expect(
        excludesGame(
          systemFolder: 'n64',
          emulatorName: 'n64.ios.retroarch',
          romPath: '/RetroArch/Games/N64/Super Mario 64.z64',
        ),
        isFalse,
      );
      expect(
        excludesGame(
          systemFolder: 'n64',
          emulatorName: 'n64.ios.retroarch',
          romPath: '$armsx2Root/imports/Super Mario 64.z64',
        ),
        isFalse,
        reason: 'ARMSX2 root ownership applies only to the PS2 launch route',
      );
      expect(
        excludesGame(
          systemFolder: 'ps2',
          emulatorName: 'ps2.ios.retroarch',
          romPath: '/RetroArch/Games/PS2/Le Hobbit.iso',
        ),
        isFalse,
      );
      for (final system in ['gc', 'wii']) {
        expect(
          excludesGame(
            systemFolder: system,
            emulatorName: '$system.ios.retroarch',
            romPath: '/RetroArch/Games/$system/Game.rvz',
          ),
          isFalse,
          reason: 'explicit RetroArch GC/Wii routes remain eligible',
        );
      }
    });
  });

  group('iOS cloud inventory exclusion', () {
    test('canonical native-emulator objects are excluded', () {
      const blocked = [
        'v2/saves/ps3/rpcs3/game/Bladestorm/00000001/BLES00050-SAVE/PARAM.SFO',
        'v2/saves/ps2/armsx2/shared/memcards/Mcd001.ps2.neosync.gz',
        'v2/saves/switch/melonx/game/Smash/profiles/11111111111111111111111111111111/01006A800016E000/0000000000000001/main',
        'v2/saves/ps3/RPCS3/game/Bladestorm/00000001/BLES00050-SAVE/PARAM.SFO',
        'v2/saves/ps2/ARMSX2/shared/memcards/Mcd001.ps2.neosync.gz',
        'v2/saves/switch/MeloNX/game/Smash/profiles/11111111111111111111111111111111/01006A800016E000/0000000000000001/main',
      ];
      for (final key in blocked) {
        expect(
          NeoSyncSavePolicy.isIosCloudFileExcluded(
            canonicalCloudFile(key),
            isIOS: true,
          ),
          isTrue,
          reason: key,
        );
      }
    });

    test('all DolphiniOS cloud objects are excluded', () {
      const unsupported = [
        'v2/saves/gc/dolphinios/shared/MemoryCardA.USA.raw.nsav',
        'v2/saves/wii/dolphinios/game/00010000524d4745/wii-data.nsav',
        'v2/saves/gc/dolphinios/game/GMSE01/gci-USA-A.nsav',
        'v2/states/gc/dolphinios/game/GMSE01/GMSE01.s01.nsav',
        'v2/states/wii/dolphinios/game/00010000524d4350/RMCP01.s01.nsav',
      ];
      for (final key in unsupported) {
        expect(
          NeoSyncSavePolicy.isIosCloudFileExcluded(
            canonicalCloudFile(key),
            isIOS: true,
          ),
          isTrue,
          reason: key,
        );
      }

      expect(
        excludesGame(
          systemFolder: 'gc',
          emulatorName: 'gc.ios.dolphinios',
          romPath: '/NeoStation/Dolphin/Library/gc/Game.rvz',
        ),
        isTrue,
      );
    });

    test('structured metadata cannot bypass the exclusion without file_name', () {
      final blocked = [
        structuredCloudFile(
          system: 'ps3',
          emulator: 'rpcs3',
          nativePath: '00000001/BLES00050-SAVE/PARAM.SFO',
        ),
        structuredCloudFile(
          system: 'ps2',
          emulator: 'armsx2',
          nativePath: 'memcards/Mcd001.ps2.neosync.gz',
          type: 'shared',
        ),
        structuredCloudFile(
          system: 'switch',
          emulator: 'melonx',
          nativePath:
              'profiles/11111111111111111111111111111111/01006A800016E000/0000000000000001/main',
        ),
      ];
      for (final file in blocked) {
        expect(
          NeoSyncSavePolicy.isIosCloudFileExcluded(file, isIOS: true),
          isTrue,
          reason: '${file.systemName}/${file.emulator}',
        );
      }
    });

    test('RetroArch objects and every non-iOS object remain eligible', () {
      const allowed = [
        'v2/saves/n64/retroarch.mupen64plus-next/game/Mario/Mario.srm',
        'v2/states/snes/retroarch.snes9x/game/Zelda/Zelda.state1',
        'v2/saves/psp/retroarch.ppsspp/game/Patapon/PPSSPP/PSP/SAVEDATA/UCES00995/PARAM.SFO',
        'v2/saves/dc/retroarch.flycast/shared/system/dc/vmu_save_A1.bin',
        'v2/saves/ps2/retroarch.play/shared/Mcd001.ps2',
        'v2/saves/gc/retroarch.dolphin/game/GMSE01/GMSE01.srm',
      ];
      for (final key in allowed) {
        expect(
          NeoSyncSavePolicy.isIosCloudFileExcluded(
            canonicalCloudFile(key),
            isIOS: true,
          ),
          isFalse,
          reason: key,
        );
      }

      final rpcs3 = canonicalCloudFile(
        'v2/saves/ps3/rpcs3/game/Game/00000001/BLES00050-SAVE/PARAM.SFO',
      );
      expect(
        NeoSyncSavePolicy.isIosCloudFileExcluded(rpcs3, isIOS: false),
        isFalse,
      );

      final dolphin = structuredCloudFile(
        system: 'gc',
        emulator: 'dolphinios',
        nativePath: 'MemoryCardA.USA.raw.nsav',
        type: 'shared',
      );
      expect(
        NeoSyncSavePolicy.isIosCloudFileExcluded(dolphin, isIOS: true),
        isTrue,
      );
      expect(
        NeoSyncSavePolicy.isIosCloudFileExcluded(dolphin, isIOS: false),
        isFalse,
      );
    });
  });

  group('DolphiniOS V1 save surface', () {
    const gc = DolphinSaveIdentity(
      system: 'gc',
      gameId: 'GMSE01',
      region: 'USA',
    );
    const wii = DolphinSaveIdentity(
      system: 'wii',
      gameId: 'RMCP01',
      region: 'EUR',
      titleId: '00010000524d4350',
    );

    test('GameCube exposes only regional RAW memory cards', () {
      final targets = DolphinSaveTarget.forGame(gc);
      expect(
        targets.map((target) => target.relativeNativePath),
        ['GC/MemoryCardA.USA.raw', 'GC/MemoryCardB.USA.raw'],
      );
      expect(targets.every((target) => target.kind == 'raw'), isTrue);
      expect(targets.every((target) => target.shared), isTrue);
      expect(
        targets.map((target) => target.cloudPath),
        [
          'v2/saves/gc/dolphinios/shared/MemoryCardA.USA.raw.nsav',
          'v2/saves/gc/dolphinios/shared/MemoryCardB.USA.raw.nsav',
        ],
      );
      expect(DolphinSaveTarget.raw('MemoryCardA.USA.251.raw'), isNull);
    });

    test('Wii exposes only one title/00010000/<hex>/data tree', () {
      final target = DolphinSaveTarget.forGame(wii).single;
      expect(target.kind, 'wii-data');
      expect(target.isState, isFalse);
      expect(
        target.relativeNativePath,
        'Wii/title/00010000/524d4350/data',
      );
      expect(
        target.cloudPath,
        'v2/saves/wii/dolphinios/game/00010000524d4350/wii-data.nsav',
      );

      const channel = DolphinSaveIdentity(
        system: 'wii',
        gameId: 'HABA',
        region: 'USA',
        titleId: '0001000148414241',
      );
      expect(channel.isValid, isTrue);
      expect(DolphinSaveTarget.forGame(channel), isEmpty);
    });

    test('GCI and savestates stay outside the active V1 contract', () {
      expect(DolphinSaveTarget.statesForGame(gc), isEmpty);
      expect(DolphinSaveTarget.statesForGame(wii), isEmpty);

      for (final key in [
        'v2/saves/gc/dolphinios/game/GMSE01/gci-USA-A.nsav',
        'v2/states/gc/dolphinios/game/GMSE01/GMSE01.s01.nsav',
        'v2/states/wii/dolphinios/game/00010000524d4350/RMCP01.s01.nsav',
      ]) {
        expect(DolphinSaveTarget.parse(key), isNull, reason: key);
      }

      expect(
        DolphinSaveTarget.parse(
          'v2/saves/gc/dolphinios/shared/MemoryCardA.USA.raw.nsav',
        ),
        isNotNull,
      );
      expect(
        DolphinSaveTarget.parse(
          'v2/saves/wii/dolphinios/game/00010000524d4350/wii-data.nsav',
        ),
        isNotNull,
      );
    });
  });
}
