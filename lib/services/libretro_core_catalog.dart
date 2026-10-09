/// Static description of the libretro cores embedded in NeoStation iOS and of
/// the NeoStation systems they run.
///
/// The cores are the official iOS builds from the libretro buildbot — the
/// same binaries RetroArch's iOS packaging script downloads — packaged as
/// `<id>_libretro.framework` by `build-utils/libretro/build_cores.py`.
library;

/// RETRO_HW_CONTEXT_* values understood by the native host.
abstract final class LibretroHardwareContext {
  static const int none = 0;
  static const int openGLES3 = 4;
  static const int vulkan = 6;
}

/// A setting NeoStation exposes in the in-game menu. Its label and the
/// labels of word values come from `LibretroLocale`; numeric values such as
/// resolutions are shown as they are.
class LibretroCuratedSetting {
  const LibretroCuratedSetting(this.key, this.labelKey, this.values,
      {this.valueLabelKeys = const <String, String>{}});

  final String key;
  final String labelKey;
  final List<String> values;
  final Map<String, String> valueLabelKeys;
}

class LibretroCore {
  const LibretroCore({
    required this.id,
    required this.displayName,
    required this.extensions,
    this.biosAnyOf = const <String>[],
    this.preferredHardwareContext = LibretroHardwareContext.none,
    this.optionDefaults = const <String, String>{},
    this.noJitOverrides = const <String, String>{},
    this.settings = const <LibretroCuratedSetting>[],
  });

  /// Framework name without the `_libretro` suffix.
  final String id;

  /// Product name, never translated.
  final String displayName;

  /// Extensions the core opens; `.zip` archives are extracted by the host.
  final Set<String> extensions;

  /// At least one of these files must exist in the System folder.
  final List<String> biosAnyOf;
  final int preferredHardwareContext;
  final Map<String, String> optionDefaults;
  final Map<String, String> noJitOverrides;
  final List<LibretroCuratedSetting> settings;
}

class LibretroSystemBinding {
  const LibretroSystemBinding({
    required this.coreId,
    required this.profile,
    this.alternatives = const <String>[],
    this.achievementsConsoleId = 0,
  });

  final String coreId;

  /// Touch overlay layout used by the native session.
  final String profile;
  final List<String> alternatives;

  /// RetroAchievements console id (rc_consoles.h), 0 when unsupported.
  final int achievementsConsoleId;
}

abstract final class LibretroCoreCatalog {
  static const Map<String, LibretroCore> cores = <String, LibretroCore>{
    'nestopia': LibretroCore(
      id: 'nestopia',
      displayName: 'Nestopia',
      extensions: {'nes', 'fds', 'unf', 'unif', 'nsf'},
    ),
    'snes9x': LibretroCore(
      id: 'snes9x',
      displayName: 'Snes9x',
      extensions: {'smc', 'sfc', 'swc', 'fig', 'bs', 'st'},
    ),
    'gambatte': LibretroCore(
      id: 'gambatte',
      displayName: 'Gambatte',
      extensions: {'gb', 'gbc', 'dmg'},
    ),
    'mgba': LibretroCore(
      id: 'mgba',
      displayName: 'mGBA',
      extensions: {'gb', 'gbc', 'gba'},
    ),
    'genesis_plus_gx': LibretroCore(
      id: 'genesis_plus_gx',
      displayName: 'Genesis Plus GX',
      extensions: {
        'mdx', 'md', 'smd', 'gen', 'bin', 'cue', 'iso', 'sms', 'bms', 'gg',
        'sg', '68k', 'sgd', 'chd', 'm3u',
      },
    ),
    'genesis_plus_gx_wide': LibretroCore(
      id: 'genesis_plus_gx_wide',
      displayName: 'Genesis Plus GX Wide',
      extensions: {
        'mdx', 'md', 'smd', 'gen', 'bin', 'cue', 'iso', 'sms', 'bms', 'gg',
        'sg', '68k', 'sgd', 'chd', 'm3u',
      },
    ),
    'picodrive': LibretroCore(
      id: 'picodrive',
      displayName: 'PicoDrive',
      extensions: {
        'bin', 'gen', 'smd', 'md', '32x', 'cue', 'iso', 'chd', 'sms', 'gg',
        'sg', 'sc', 'm3u', '68k', 'sgd', 'pco',
      },
    ),
    'fbneo': LibretroCore(
      id: 'fbneo',
      displayName: 'FinalBurn Neo',
      extensions: {'zip', '7z', 'cue', 'ccd'},
    ),
    'desmume': LibretroCore(
      id: 'desmume',
      displayName: 'DeSmuME',
      extensions: {'nds', 'ids', 'bin'},
      optionDefaults: {'desmume_screens_layout': 'left/right'},
      settings: [
        LibretroCuratedSetting(
          'desmume_screens_layout',
          'settingScreenLayout',
          [
            'left/right',
            'top/bottom',
            'right/left',
            'bottom/top',
            'top only',
            'bottom only',
            'hybrid/top',
            'hybrid/bottom',
          ],
          valueLabelKeys: {
            'left/right': 'layoutLeftRight',
            'top/bottom': 'layoutTopBottom',
            'right/left': 'layoutRightLeft',
            'bottom/top': 'layoutBottomTop',
            'top only': 'layoutTopOnly',
            'bottom only': 'layoutBottomOnly',
            'hybrid/top': 'layoutHybridTop',
            'hybrid/bottom': 'layoutHybridBottom',
          },
        ),
      ],
    ),
    'mupen64plus_next': LibretroCore(
      id: 'mupen64plus_next',
      displayName: 'Mupen64Plus-Next',
      extensions: {'n64', 'v64', 'z64', 'ndd', 'bin', 'u1'},
      preferredHardwareContext: LibretroHardwareContext.openGLES3,
      noJitOverrides: {'mupen64plus-cpucore': 'cached_interpreter'},
      settings: [
        LibretroCuratedSetting(
          'mupen64plus-43screensize',
          'settingResolution',
          ['640x480', '960x720', '1280x960', '1440x1080', '1600x1200', '1920x1440'],
        ),
      ],
    ),
    'mednafen_psx_hw': LibretroCore(
      id: 'mednafen_psx_hw',
      displayName: 'Beetle PSX HW',
      extensions: {'cue', 'toc', 'm3u', 'ccd', 'exe', 'pbp', 'chd', 'bin'},
      biosAnyOf: ['scph5500.bin', 'scph5501.bin', 'scph5502.bin'],
      // The iOS build links OpenGLES; its Vulkan renderer stays available.
      preferredHardwareContext: LibretroHardwareContext.openGLES3,
      noJitOverrides: {'beetle_psx_hw_cpu_dynarec': 'disabled'},
      settings: [
        LibretroCuratedSetting(
          'beetle_psx_hw_internal_resolution',
          'settingResolution',
          ['1x(native)', '2x', '4x', '8x'],
          valueLabelKeys: {'1x(native)': 'resolutionNative'},
        ),
      ],
    ),
    'mednafen_psx': LibretroCore(
      id: 'mednafen_psx',
      displayName: 'Beetle PSX',
      extensions: {'cue', 'toc', 'm3u', 'ccd', 'exe', 'pbp', 'chd', 'bin'},
      biosAnyOf: ['scph5500.bin', 'scph5501.bin', 'scph5502.bin'],
      noJitOverrides: {'beetle_psx_cpu_dynarec': 'disabled'},
    ),
    'ppsspp': LibretroCore(
      id: 'ppsspp',
      displayName: 'PPSSPP',
      extensions: {'elf', 'iso', 'cso', 'prx', 'pbp', 'chd'},
      preferredHardwareContext: LibretroHardwareContext.openGLES3,
      optionDefaults: {'ppsspp_internal_resolution': '960x544'},
      noJitOverrides: {'ppsspp_cpu_core': 'IR JIT'},
      settings: [
        LibretroCuratedSetting(
          'ppsspp_internal_resolution',
          'settingResolution',
          ['480x272', '960x544', '1440x816', '1920x1088', '2400x1360'],
        ),
      ],
    ),
    'azahar': LibretroCore(
      id: 'azahar',
      displayName: 'Azahar',
      extensions: {
        '3ds', '3dsx', 'z3dsx', 'elf', 'axf', 'cci', 'zcci', 'cxi', 'zcxi',
        'app',
      },
      preferredHardwareContext: LibretroHardwareContext.vulkan,
      noJitOverrides: {
        'azahar_use_cpu_jit': 'disabled',
        'citra_use_cpu_jit': 'disabled',
      },
    ),
  };

  static const Map<String, LibretroSystemBinding> systems =
      <String, LibretroSystemBinding>{
    'nes': LibretroSystemBinding(coreId: 'nestopia', profile: 'nes', achievementsConsoleId: 7),
    'fc': LibretroSystemBinding(coreId: 'nestopia', profile: 'nes', achievementsConsoleId: 7),
    'nes-hacks': LibretroSystemBinding(coreId: 'nestopia', profile: 'nes', achievementsConsoleId: 7),
    'fds': LibretroSystemBinding(coreId: 'nestopia', profile: 'nes', achievementsConsoleId: 7),
    'snes': LibretroSystemBinding(coreId: 'snes9x', profile: 'snes', achievementsConsoleId: 3),
    'sfc': LibretroSystemBinding(coreId: 'snes9x', profile: 'snes', achievementsConsoleId: 3),
    'snes-hacks': LibretroSystemBinding(coreId: 'snes9x', profile: 'snes', achievementsConsoleId: 3),
    'sfc-hacks': LibretroSystemBinding(coreId: 'snes9x', profile: 'snes', achievementsConsoleId: 3),
    'satellaview': LibretroSystemBinding(coreId: 'snes9x', profile: 'snes', achievementsConsoleId: 3),
    'gb': LibretroSystemBinding(coreId: 'gambatte', profile: 'gb', alternatives: ['mgba'], achievementsConsoleId: 4),
    'gb-hacks': LibretroSystemBinding(coreId: 'gambatte', profile: 'gb', alternatives: ['mgba'], achievementsConsoleId: 4),
    'gbc': LibretroSystemBinding(coreId: 'gambatte', profile: 'gb', alternatives: ['mgba'], achievementsConsoleId: 6),
    'gbc-hacks': LibretroSystemBinding(coreId: 'gambatte', profile: 'gb', alternatives: ['mgba'], achievementsConsoleId: 6),
    'gba': LibretroSystemBinding(coreId: 'mgba', profile: 'gba', achievementsConsoleId: 5),
    'gba-hacks': LibretroSystemBinding(coreId: 'mgba', profile: 'gba', achievementsConsoleId: 5),
    'md': LibretroSystemBinding(coreId: 'genesis_plus_gx', profile: 'md', alternatives: ['genesis_plus_gx_wide', 'picodrive'], achievementsConsoleId: 1),
    'genesis': LibretroSystemBinding(coreId: 'genesis_plus_gx', profile: 'md', alternatives: ['genesis_plus_gx_wide', 'picodrive'], achievementsConsoleId: 1),
    'md-hacks': LibretroSystemBinding(coreId: 'genesis_plus_gx', profile: 'md', alternatives: ['genesis_plus_gx_wide', 'picodrive'], achievementsConsoleId: 1),
    'gen-hacks': LibretroSystemBinding(coreId: 'genesis_plus_gx', profile: 'md', alternatives: ['genesis_plus_gx_wide', 'picodrive'], achievementsConsoleId: 1),
    'mcd': LibretroSystemBinding(coreId: 'genesis_plus_gx', profile: 'md', alternatives: ['picodrive'], achievementsConsoleId: 9),
    'scd': LibretroSystemBinding(coreId: 'genesis_plus_gx', profile: 'md', alternatives: ['picodrive'], achievementsConsoleId: 9),
    'sms': LibretroSystemBinding(coreId: 'genesis_plus_gx', profile: 'sms', alternatives: ['picodrive'], achievementsConsoleId: 11),
    'mark3': LibretroSystemBinding(coreId: 'genesis_plus_gx', profile: 'sms', alternatives: ['picodrive'], achievementsConsoleId: 11),
    'gg': LibretroSystemBinding(coreId: 'genesis_plus_gx', profile: 'sms', alternatives: ['picodrive'], achievementsConsoleId: 15),
    'gg-hacks': LibretroSystemBinding(coreId: 'genesis_plus_gx', profile: 'sms', alternatives: ['picodrive'], achievementsConsoleId: 15),
    'sg1k': LibretroSystemBinding(coreId: 'genesis_plus_gx', profile: 'sms', achievementsConsoleId: 33),
    '32x': LibretroSystemBinding(coreId: 'picodrive', profile: 'md', achievementsConsoleId: 10),
    'pico': LibretroSystemBinding(coreId: 'picodrive', profile: 'md'),
    'arc': LibretroSystemBinding(coreId: 'fbneo', profile: 'arcade', achievementsConsoleId: 27),
    'fbneo': LibretroSystemBinding(coreId: 'fbneo', profile: 'arcade', achievementsConsoleId: 27),
    'cps1': LibretroSystemBinding(coreId: 'fbneo', profile: 'arcade', achievementsConsoleId: 27),
    'cps2': LibretroSystemBinding(coreId: 'fbneo', profile: 'arcade', achievementsConsoleId: 27),
    'cps3': LibretroSystemBinding(coreId: 'fbneo', profile: 'arcade', achievementsConsoleId: 27),
    'neogeo': LibretroSystemBinding(coreId: 'fbneo', profile: 'arcade', achievementsConsoleId: 27),
    'ds': LibretroSystemBinding(coreId: 'desmume', profile: 'nds', achievementsConsoleId: 18),
    'n64': LibretroSystemBinding(coreId: 'mupen64plus_next', profile: 'n64', achievementsConsoleId: 2),
    'ps1': LibretroSystemBinding(coreId: 'mednafen_psx_hw', profile: 'psx', alternatives: ['mednafen_psx'], achievementsConsoleId: 12),
    'psp': LibretroSystemBinding(coreId: 'ppsspp', profile: 'psp', achievementsConsoleId: 41),
    'pspminis': LibretroSystemBinding(coreId: 'ppsspp', profile: 'psp', achievementsConsoleId: 41),
    '3ds': LibretroSystemBinding(coreId: 'azahar', profile: '3ds', achievementsConsoleId: 62),
  };

  static LibretroSystemBinding? bindingFor(String folderName) =>
      systems[folderName.toLowerCase()];

  static bool handles(String folderName) =>
      systems.containsKey(folderName.toLowerCase());

  /// Default core first, then the alternatives a game may be switched to.
  static List<LibretroCore> coresFor(String folderName) {
    final binding = bindingFor(folderName);
    if (binding == null) return const <LibretroCore>[];
    return <String>[binding.coreId, ...binding.alternatives]
        .map((id) => cores[id])
        .whereType<LibretroCore>()
        .toList(growable: false);
  }

  /// Extensions accepted by the import picker for a system.
  static Set<String> importExtensionsFor(String folderName) {
    final extensions = <String>{'zip'};
    for (final core in coresFor(folderName)) {
      extensions.addAll(core.extensions);
    }
    return extensions;
  }
}
