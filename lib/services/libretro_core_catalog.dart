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
    this.lockedOptions = const <String, String>{},
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

  /// Core options NeoStation imposes for the whole session, before
  /// `retro_init`, and shows read-only: the screen crop, the touch screen and
  /// the controls of dual-screen consoles depend on them.
  final Map<String, String> lockedOptions;
  final List<LibretroCuratedSetting> settings;
}

class LibretroSystemBinding {
  const LibretroSystemBinding({
    required this.coreId,
    required this.console,
    this.alternatives = const <String>[],
    this.achievementsConsoleId = 0,
  });

  final String coreId;

  /// NeoStation console of the system (key of [LibretroCoreCatalog.consoles]):
  /// skins, screen format, shaders and controls belong to the console, not
  /// to the core.
  final String console;
  final List<String> alternatives;

  /// RetroAchievements console id (rc_consoles.h), 0 when unsupported.
  final int achievementsConsoleId;
}

/// A console as NeoStation's embedded engine presents it: the key of its
/// frontend settings and skins, whatever core or system folder runs it.
class LibretroConsole {
  const LibretroConsole({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.importSystem,
    this.catalogSystems = const <String>[],
    this.regions = const <String, List<double>>{},
  });

  final String id;

  /// Product name, never translated.
  final String name;

  /// Nominal picture size in console pixels; 0 x 0 when it varies (arcade
  /// boards), so no skin crop is ever trusted for it.
  final int width;
  final int height;

  /// System folder (an `assets/systems` id bound to this console) that games
  /// imported for the console go to.
  final String importSystem;

  /// Lowercase `systems` codes of the Provenance skin catalog for the console.
  final List<String> catalogSystems;

  /// Dual-screen consoles: normalized `[x, y, width, height]` of the "top"
  /// and "bottom" screens in the core picture (the core renders them
  /// stacked).
  final Map<String, List<double>> regions;

  bool get isDualScreen => regions.isNotEmpty;

  /// Entry of [LibretroCoreCatalog.consoleGeometry] for this console.
  Map<String, Object> get geometry => <String, Object>{
        'size': <int>[width, height],
        if (regions.isNotEmpty) 'regions': regions,
      };
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
      noJitOverrides: {'desmume_cpu_mode': 'interpreter'},
      // The core always renders both screens stacked with no gap and reads
      // RETRO_DEVICE_POINTER as a touch screen (its default "mouse" pointer
      // type ignores it); NeoStation crops and places the two screens
      // itself, so DeSmuME's own screen layout is no longer offered.
      lockedOptions: {
        'desmume_screens_layout': 'top/bottom',
        'desmume_screens_gap': '0',
        'desmume_pointer_type': 'touch',
        'desmume_pointer_mouse': 'enabled',
      },
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
      // No no-JIT override: the pinned iOS builds of both Beetle PSX cores
      // have no Lightrec dynarec option, and test/libretro_core_options_test.py
      // flags one if a future core build adds it.
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
      // The libretro build keeps Citra's option keys. Both the ARM11 JIT and
      // the PICA shader JIT emit machine code.
      noJitOverrides: {
        'citra_use_cpu_jit': 'disabled',
        'citra_use_shader_jit': 'disabled',
      },
      // Top screen above the centred bottom screen, never swapped by the
      // core; the C-stick stays a stick instead of also driving a touch
      // cursor; stereoscopic modes would change the picture NeoStation crops.
      lockedOptions: {
        'citra_layout_option': 'default',
        'citra_swap_screen': 'Top',
        'citra_analog_function': 'c_stick',
        'citra_render_3d': 'off',
      },
    ),
  };

  static const Map<String, LibretroSystemBinding> systems =
      <String, LibretroSystemBinding>{
    'nes': LibretroSystemBinding(coreId: 'nestopia', console: 'nes', achievementsConsoleId: 7),
    'fc': LibretroSystemBinding(coreId: 'nestopia', console: 'nes', achievementsConsoleId: 7),
    'nes-hacks': LibretroSystemBinding(coreId: 'nestopia', console: 'nes', achievementsConsoleId: 7),
    'fds': LibretroSystemBinding(coreId: 'nestopia', console: 'nes', achievementsConsoleId: 7),
    'snes': LibretroSystemBinding(coreId: 'snes9x', console: 'snes', achievementsConsoleId: 3),
    'sfc': LibretroSystemBinding(coreId: 'snes9x', console: 'snes', achievementsConsoleId: 3),
    'snes-hacks': LibretroSystemBinding(coreId: 'snes9x', console: 'snes', achievementsConsoleId: 3),
    'sfc-hacks': LibretroSystemBinding(coreId: 'snes9x', console: 'snes', achievementsConsoleId: 3),
    'satellaview': LibretroSystemBinding(coreId: 'snes9x', console: 'snes', achievementsConsoleId: 3),
    'gb': LibretroSystemBinding(coreId: 'gambatte', console: 'gb', alternatives: ['mgba'], achievementsConsoleId: 4),
    'gb-hacks': LibretroSystemBinding(coreId: 'gambatte', console: 'gb', alternatives: ['mgba'], achievementsConsoleId: 4),
    'gbc': LibretroSystemBinding(coreId: 'gambatte', console: 'gbc', alternatives: ['mgba'], achievementsConsoleId: 6),
    'gbc-hacks': LibretroSystemBinding(coreId: 'gambatte', console: 'gbc', alternatives: ['mgba'], achievementsConsoleId: 6),
    'gba': LibretroSystemBinding(coreId: 'mgba', console: 'gba', achievementsConsoleId: 5),
    'gba-hacks': LibretroSystemBinding(coreId: 'mgba', console: 'gba', achievementsConsoleId: 5),
    'md': LibretroSystemBinding(coreId: 'genesis_plus_gx', console: 'md', alternatives: ['genesis_plus_gx_wide', 'picodrive'], achievementsConsoleId: 1),
    'genesis': LibretroSystemBinding(coreId: 'genesis_plus_gx', console: 'md', alternatives: ['genesis_plus_gx_wide', 'picodrive'], achievementsConsoleId: 1),
    'md-hacks': LibretroSystemBinding(coreId: 'genesis_plus_gx', console: 'md', alternatives: ['genesis_plus_gx_wide', 'picodrive'], achievementsConsoleId: 1),
    'gen-hacks': LibretroSystemBinding(coreId: 'genesis_plus_gx', console: 'md', alternatives: ['genesis_plus_gx_wide', 'picodrive'], achievementsConsoleId: 1),
    'mcd': LibretroSystemBinding(coreId: 'genesis_plus_gx', console: 'mcd', alternatives: ['picodrive'], achievementsConsoleId: 9),
    'scd': LibretroSystemBinding(coreId: 'genesis_plus_gx', console: 'mcd', alternatives: ['picodrive'], achievementsConsoleId: 9),
    'sms': LibretroSystemBinding(coreId: 'genesis_plus_gx', console: 'sms', alternatives: ['picodrive'], achievementsConsoleId: 11),
    'mark3': LibretroSystemBinding(coreId: 'genesis_plus_gx', console: 'sms', alternatives: ['picodrive'], achievementsConsoleId: 11),
    'gg': LibretroSystemBinding(coreId: 'genesis_plus_gx', console: 'gg', alternatives: ['picodrive'], achievementsConsoleId: 15),
    'gg-hacks': LibretroSystemBinding(coreId: 'genesis_plus_gx', console: 'gg', alternatives: ['picodrive'], achievementsConsoleId: 15),
    'sg1k': LibretroSystemBinding(coreId: 'genesis_plus_gx', console: 'sg1000', achievementsConsoleId: 33),
    '32x': LibretroSystemBinding(coreId: 'picodrive', console: '32x', achievementsConsoleId: 10),
    'pico': LibretroSystemBinding(coreId: 'picodrive', console: 'md'),
    'arc': LibretroSystemBinding(coreId: 'fbneo', console: 'arcade', achievementsConsoleId: 27),
    'fbneo': LibretroSystemBinding(coreId: 'fbneo', console: 'arcade', achievementsConsoleId: 27),
    'cps1': LibretroSystemBinding(coreId: 'fbneo', console: 'arcade', achievementsConsoleId: 27),
    'cps2': LibretroSystemBinding(coreId: 'fbneo', console: 'arcade', achievementsConsoleId: 27),
    'cps3': LibretroSystemBinding(coreId: 'fbneo', console: 'arcade', achievementsConsoleId: 27),
    'neogeo': LibretroSystemBinding(coreId: 'fbneo', console: 'arcade', achievementsConsoleId: 27),
    'ds': LibretroSystemBinding(coreId: 'desmume', console: 'nds', achievementsConsoleId: 18),
    'n64': LibretroSystemBinding(coreId: 'mupen64plus_next', console: 'n64', achievementsConsoleId: 2),
    'ps1': LibretroSystemBinding(coreId: 'mednafen_psx_hw', console: 'psx', alternatives: ['mednafen_psx'], achievementsConsoleId: 12),
    'psp': LibretroSystemBinding(coreId: 'ppsspp', console: 'psp', achievementsConsoleId: 41),
    'pspminis': LibretroSystemBinding(coreId: 'ppsspp', console: 'psp', achievementsConsoleId: 41),
    '3ds': LibretroSystemBinding(coreId: 'azahar', console: '3ds', achievementsConsoleId: 62),
  };

  /// The 17 consoles of the embedded engine, in the order of the native
  /// `+[LibretroInputMap consoles]`.
  static const Map<String, LibretroConsole> consoles = <String, LibretroConsole>{
    'nes': LibretroConsole(
      id: 'nes',
      name: 'NES',
      width: 256,
      height: 240,
      importSystem: 'nes',
      catalogSystems: ['nes'],
    ),
    'snes': LibretroConsole(
      id: 'snes',
      name: 'Super Nintendo',
      width: 256,
      height: 224,
      importSystem: 'snes',
      catalogSystems: ['snes'],
    ),
    'gb': LibretroConsole(
      id: 'gb',
      name: 'Game Boy',
      width: 160,
      height: 144,
      importSystem: 'gb',
      // The catalog files Game Boy skins under "gbc".
      catalogSystems: ['gbc', 'gb'],
    ),
    'gbc': LibretroConsole(
      id: 'gbc',
      name: 'Game Boy Color',
      width: 160,
      height: 144,
      importSystem: 'gbc',
      catalogSystems: ['gbc'],
    ),
    'gba': LibretroConsole(
      id: 'gba',
      name: 'Game Boy Advance',
      width: 240,
      height: 160,
      importSystem: 'gba',
      catalogSystems: ['gba'],
    ),
    'md': LibretroConsole(
      id: 'md',
      name: 'Mega Drive / Genesis',
      width: 320,
      height: 224,
      importSystem: 'md',
      catalogSystems: ['genesis'],
    ),
    'mcd': LibretroConsole(
      id: 'mcd',
      name: 'Mega-CD / Sega CD',
      width: 320,
      height: 224,
      importSystem: 'mcd',
      catalogSystems: ['genesis', 'segacd'],
    ),
    '32x': LibretroConsole(
      id: '32x',
      name: '32X',
      width: 320,
      height: 224,
      importSystem: '32x',
      catalogSystems: ['genesis', 'sega32x', '32x'],
    ),
    'sms': LibretroConsole(
      id: 'sms',
      name: 'Master System',
      width: 256,
      height: 192,
      importSystem: 'sms',
      catalogSystems: ['mastersystem'],
    ),
    'gg': LibretroConsole(
      id: 'gg',
      name: 'Game Gear',
      width: 160,
      height: 144,
      importSystem: 'gg',
      catalogSystems: ['gamegear'],
    ),
    'sg1000': LibretroConsole(
      id: 'sg1000',
      name: 'SG-1000',
      width: 256,
      height: 192,
      importSystem: 'sg1k',
      catalogSystems: ['sg1000'],
    ),
    'arcade': LibretroConsole(
      id: 'arcade',
      name: 'Arcade',
      width: 0,
      height: 0,
      importSystem: 'arc',
      catalogSystems: ['mame'],
    ),
    'nds': LibretroConsole(
      id: 'nds',
      name: 'Nintendo DS',
      width: 256,
      height: 384,
      importSystem: 'ds',
      catalogSystems: ['nds'],
      regions: {
        'top': [0, 0, 1, 0.5],
        'bottom': [0, 0.5, 1, 0.5],
      },
    ),
    'n64': LibretroConsole(
      id: 'n64',
      name: 'Nintendo 64',
      width: 320,
      height: 240,
      importSystem: 'n64',
      catalogSystems: ['n64'],
    ),
    'psx': LibretroConsole(
      id: 'psx',
      name: 'PlayStation',
      width: 320,
      height: 240,
      importSystem: 'ps1',
      catalogSystems: ['psx'],
    ),
    'psp': LibretroConsole(
      id: 'psp',
      name: 'PlayStation Portable',
      width: 480,
      height: 272,
      importSystem: 'psp',
      catalogSystems: ['psp'],
    ),
    '3ds': LibretroConsole(
      id: '3ds',
      name: 'Nintendo 3DS',
      width: 400,
      height: 480,
      importSystem: '3ds',
      catalogSystems: ['threeds', '3ds'],
      // 400x240 top screen above the 320x240 bottom screen, centred.
      regions: {
        'top': [0, 0, 1, 0.5],
        'bottom': [0.1, 0.5, 0.8, 0.5],
      },
    ),
  };

  static LibretroSystemBinding? bindingFor(String folderName) =>
      systems[folderName.toLowerCase()];

  static bool handles(String folderName) =>
      systems.containsKey(folderName.toLowerCase());

  /// Console of a bound system folder, null when the engine does not run it.
  static LibretroConsole? consoleFor(String folderName) {
    final binding = bindingFor(folderName);
    return binding == null ? null : consoles[binding.console];
  }

  /// Geometry of every console for the native skin parser and session
  /// (`+[LibretroSkin skinWithDirectory:consoleGeometry:errorCode:]`):
  /// `{console: {"size": [w, h], "regions": {"top": [x, y, w, h], ...}}}`.
  static Map<String, Map<String, Object>> consoleGeometry() =>
      <String, Map<String, Object>>{
        for (final console in consoles.values) console.id: console.geometry,
      };

  /// Catalog key of a system: its id when the engine runs it, else the first
  /// folder alias it runs, else the folder name. A system copy named after
  /// an alias folder ("n3ds", "PlayStation Portable") keeps its canonical id,
  /// so it still launches with the embedded core and keeps its preferences.
  static String canonicalSystem({
    String? id,
    Iterable<String> folders = const <String>[],
    required String folderName,
  }) {
    if (id != null && handles(id)) return id.toLowerCase();
    for (final folder in folders) {
      if (handles(folder)) return folder.toLowerCase();
    }
    return folderName.toLowerCase();
  }

  /// Default core first, then the alternatives a game may be switched to.
  static List<LibretroCore> coresFor(String folderName) {
    final binding = bindingFor(folderName);
    if (binding == null) return const <LibretroCore>[];
    return <String>[binding.coreId, ...binding.alternatives]
        .map((id) => cores[id])
        .whereType<LibretroCore>()
        .toList(growable: false);
  }

  /// Extensions accepted by the import picker for a system: what its cores
  /// open plus `.zip`. With [indexed] (the extensions the library scanner
  /// lists for the system, from its `assets/systems` definition), only those
  /// the scanner also indexes, so an imported game always appears.
  static Set<String> importExtensionsFor(String folderName, {Iterable<String>? indexed}) {
    final extensions = <String>{'zip'};
    for (final core in coresFor(folderName)) {
      extensions.addAll(core.extensions);
    }
    if (indexed == null) return extensions;
    final scanned = <String>{
      for (final extension in indexed) _bareExtension(extension),
    };
    return extensions.intersection(scanned);
  }

  static String _bareExtension(String extension) {
    final trimmed = extension.trim().toLowerCase();
    return trimmed.startsWith('.') ? trimmed.substring(1) : trimmed;
  }
}
