import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_core_catalog.dart';
import 'package:neostation/services/retroarch_core_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'only reviewed cores available for a console; no cross-console override',
    () {
      expect(
        RetroArchCoreCatalog.coresForSystem(
          ' NES ',
        ).map((core) => core.identifier),
        ['fceumm', 'nestopia', 'fbneo', 'mesen', 'quicknes', 'rustynes'],
      );
      expect(RetroArchCoreCatalog.findCore('nes', 'mgba'), isNull);
      for (final folder in [
        'gc',
        'wii',
        'ps2',
        'ps3',
        '3ds',
        'switch',
        'wiiu',
      ]) {
        expect(RetroArchCoreCatalog.supportsSystem(folder), isFalse);
      }
      expect(
        RetroArchCoreCatalog.coresForSystem(
          'ds',
        ).map((core) => core.identifier),
        ['noods', 'skyemu'],
      );
      for (final entry in {
        'ds': ['desmume', 'melondsds'],
        'snes': ['bsnes_hd_beta', 'snes9x2005', 'snes9x2005_plus'],
        'ps1': ['mednafen_psx_hw', 'swanstation'],
        'sat': ['kronos'],
        'gb': ['dolphin'],
        'n64': [
          'parallel_n64',
          'mupen64plus_next_gles2',
          'mupen64plus_next_gles3',
        ],
      }.entries) {
        for (final identifier in entry.value) {
          expect(RetroArchCoreCatalog.findCore(entry.key, identifier), isNull);
        }
      }
    },
  );

  test(
    'catalogue identities and console membership match pinned package input',
    () {
      final input =
          jsonDecode(
                File('build-utils/retroarch/source.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final packaged = (input['cores'] as List).cast<Map<String, dynamic>>();
      expect(
        packaged.map((core) => core['id']).toSet(),
        RetroArchCoreCatalog.cores.map((core) => core.identifier).toSet(),
      );
      for (final core in RetroArchCoreCatalog.cores) {
        final package = packaged.singleWhere(
          (item) => item['id'] == core.identifier,
        );
        expect(
          package['binary'],
          'Frameworks/${core.frameworkName}/${core.executableName}',
        );
        expect((package['systemIds'] as List).toSet(), core.systems);
        expect(
          (package['supportedExtensions'] as List).toSet(),
          core.validExtensions,
        );
      }
    },
  );

  test(
    'more console variants retain existing defaults and exact identities',
    () {
      expect(
        RetroArchCoreCatalog.coresForSystem(
          'snes',
        ).map((core) => core.identifier),
        ['snes9x', 'bsnes', 'bsnes-jg', 'fbneo', 'mesen-s', 'snes9x2010'],
      );
      expect(
        RetroArchCoreCatalog.coresForSystem(
          'md',
        ).map((core) => core.identifier),
        [
          'genesis_plus_gx',
          'picodrive',
          'clownmdemu',
          'fbneo',
          'genesis_plus_gx_wide',
        ],
      );
      expect(RetroArchCoreCatalog.defaultCore('snes').identifier, 'snes9x');
      expect(
        RetroArchCoreCatalog.defaultCore('md').identifier,
        'genesis_plus_gx',
      );
      expect(
        RetroArchCoreCatalog.defaultCore('ps1').identifier,
        'pcsx_rearmed',
      );
      expect(RetroArchCoreCatalog.findCore('c64', 'vice_x128'), isNull);
      expect(RetroArchCoreCatalog.findCore('c64', 'vice_xscpu64'), isNull);
    },
  );

  test(
    'known foreign filename aliases remain restricted to compatible consoles',
    () {
      for (final identifier in [
        'snes9x_libretro',
        'snes9x_libretro.so',
        'snes9x_libretro.dll',
        'snes9x_libretro.dylib',
        'snes9x.libretro',
        'snes9x.libretro.framework',
      ]) {
        expect(
          RetroArchCoreCatalog.findCore('snes', identifier)?.identifier,
          'snes9x',
        );
        expect(RetroArchCoreCatalog.findCore('nes', identifier), isNull);
      }
      expect(
        RetroArchCoreCatalog.findCore(
          'md',
          'genesis_plus_gx_libretro.so',
        )?.identifier,
        'genesis_plus_gx',
      );
      expect(
        RetroArchCoreCatalog.findCore('snes', 'unknown_libretro.so'),
        isNull,
      );
      expect(
        RetroArchCoreCatalog.findCore('snes', 'snes9x_libretro.so.backup'),
        isNull,
      );
      expect(
        RetroArchCoreCatalog.findCore('snes', '../snes9x_libretro.so'),
        isNull,
      );
    },
  );

  test('game extension union preserves formats and disc sidecars', () {
    expect(
      RetroArchCoreCatalog.findCore('md', 'clownmdemu')!.validExtensions,
      containsAll(['bin', 'md', 'gen', 'cue', 'iso', 'chd']),
    );
    expect(
      RetroArchCoreCatalog.recognizedGameExtensions,
      containsAll([
        'nes',
        'sfc',
        'nds',
        'd64',
        'prg',
        'adf',
        'cue',
        'm3u',
        'sub',
        'sbi',
        'zip',
        '7z',
      ]),
    );
    expect(RetroArchCoreCatalog.recognizedGameExtensions, isNot(contains('/')));
    expect(
      RetroArchCoreCatalog.recognizedGameExtensions,
      isNot(contains('dylib')),
    );
    for (final system in ['psp', 'pspminis']) {
      final core = RetroArchCoreCatalog.findCore(system, 'ppsspp');
      expect(core, isNotNull);
      expect(core!.validExtensions, {'elf', 'iso', 'cso', 'prx', 'pbp', 'chd'});
    }
    expect(RetroArchCoreCatalog.recognizedGameExtensions, contains('cso'));
    expect(
      RetroArchCoreCatalog.recognizedGameExtensions,
      containsAll(['n64', 'v64', 'z64', 'ndd', 'u1']),
    );
  });

  test('N64 is pinned to the reviewed GLES3 interpreter profile', () {
    final source =
        jsonDecode(File('build-utils/retroarch/source.json').readAsStringSync())
            as Map<String, dynamic>;
    final pin = (source['cores'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((entry) => entry['id'] == 'mupen64plus_next');
    final core = RetroArchCoreCatalog.defaultCore('n64');
    expect(core.identifier, 'mupen64plus_next');
    expect(core.frameworkName, 'mupen64plus.next.libretro.framework');
    expect(core.validExtensions, {'n64', 'v64', 'z64', 'ndd', 'bin', 'u1'});
    expect(
      pin['sha256'],
      '9e218101d03556d2c7decd182706174a3fc738ab7fba946bc9bd36e6eee38237',
    );
    expect(
      pin['infoSha256'],
      '8d1fcd13a17310e233be4ff247bf1032f8f786fe685e24cef5ed4ea474ccdfb6',
    );
    expect(pin['forcedOptions'], {
      'mupen64plus-cpucore': 'pure_interpreter',
      'mupen64plus-rdp-plugin': 'gliden64',
      'mupen64plus-rsp-plugin': 'hle',
      'mupen64plus-ThreadedRenderer': 'False',
    });
    expect(
      RetroArchCoreCatalog.findCore(
        'n64',
        'mupen64plus_next_libretro.so',
      )?.identifier,
      'mupen64plus_next',
    );
    expect(RetroArchCoreCatalog.findCore('psp', 'mupen64plus_next'), isNull);
  });

  test('system choice persists without changing other consoles', () async {
    await RetroArchCorePreferences.setPreferredCore('nes', 'nestopia');
    expect(
      (await RetroArchCorePreferences.preferredCore('NES')).identifier,
      'nestopia',
    );
    expect(
      (await RetroArchCorePreferences.preferredCore('gba')).identifier,
      'mgba',
    );
    await expectLater(
      RetroArchCorePreferences.setPreferredCore('nes', 'mgba'),
      throwsArgumentError,
    );
    expect(
      (await RetroArchCorePreferences.preferredCore('nes')).identifier,
      'nestopia',
    );
  });

  test(
    'a compatible old system choice is proposed without persisting it',
    () async {
      final chosen = await RetroArchCorePreferences.preferredCore(
        'nes',
        readLegacyCore: (_) async => 'nestopia.libretro.framework',
      );
      expect(chosen.identifier, 'nestopia');
      expect(await RetroArchCorePreferences.systemCoreOverride('nes'), isNull);
      final incompatible = await RetroArchCorePreferences.preferredCore(
        'nes',
        readLegacyCore: (_) async => 'mgba',
      );
      expect(incompatible.identifier, 'fceumm');
      await RetroArchCorePreferences.setPreferredCore('nes', 'fceumm');
      final explicit = await RetroArchCorePreferences.preferredCore(
        'nes',
        readLegacyCore: (_) =>
            throw StateError('SQL must not replace a new choice'),
      );
      expect(explicit.identifier, 'fceumm');
    },
  );

  test(
    'game override can explicitly inherit system choice and keys never collide',
    () async {
      expect(
        await RetroArchCorePreferences.gameCoreOverride('nes', 'A:B'),
        isNull,
      );
      await RetroArchCorePreferences.setGameCoreOverride(
        'nes',
        'A:B',
        'nestopia',
      );
      await RetroArchCorePreferences.setGameCoreOverride('nes', 'A', 'fceumm');
      expect(
        await RetroArchCorePreferences.gameCoreOverride('nes', 'A:B'),
        'nestopia',
      );
      expect(
        await RetroArchCorePreferences.gameCoreOverride('nes', 'A'),
        'fceumm',
      );
      await RetroArchCorePreferences.setGameCoreOverride('nes', 'A:B', null);
      expect(await RetroArchCorePreferences.gameCoreOverride('nes', 'A:B'), '');
      expect(
        await RetroArchCorePreferences.gameCoreOverride('nes', 'A'),
        'fceumm',
      );
    },
  );

  test(
    'retired saved core does not silently start a different emulator',
    () async {
      SharedPreferences.setMockInitialValues({
        'retroarch_embedded_core_v1:nes': 'dolphin',
      });
      await expectLater(
        RetroArchCorePreferences.preferredCore('nes'),
        throwsStateError,
      );
    },
  );
}
