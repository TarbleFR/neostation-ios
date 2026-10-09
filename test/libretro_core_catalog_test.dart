import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/libretro_core_catalog.dart';

Map<String, Map<String, dynamic>> _systemsById() {
  final systems = <String, Map<String, dynamic>>{};
  for (final file in Directory('assets/systems').listSync().whereType<File>()) {
    if (!file.path.endsWith('.json')) continue;
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final system = json['system'];
    if (system is Map<String, dynamic> && system['id'] is String) {
      systems[system['id'] as String] = json;
    }
  }
  return systems;
}

Set<String> _iosUrlSchemes(Map<String, dynamic> json) {
  final schemes = <String>{};
  for (final emulator in (json['emulators'] as List? ?? const [])) {
    final ios = (emulator as Map)['platforms']?['ios'];
    if (ios is Map && ios['url_scheme'] is String) schemes.add(ios['url_scheme'] as String);
    if (ios is Map && ios['embedded'] == true) schemes.add('embedded');
  }
  return schemes;
}

void main() {
  final systems = _systemsById();
  final manifest = jsonDecode(File('build-utils/libretro/cores.json').readAsStringSync())
      as Map<String, dynamic>;
  final packaged = {
    for (final core in manifest['cores'] as List) (core as Map)['id'] as String,
  };

  test('bound systems exist and were RetroArch systems, never another engine', () {
    for (final folder in LibretroCoreCatalog.systems.keys) {
      expect(systems.containsKey(folder), isTrue, reason: folder);
      expect(_iosUrlSchemes(systems[folder]!), contains('retroarch'), reason: folder);
      expect(_iosUrlSchemes(systems[folder]!), isNot(contains('embedded')), reason: folder);
    }
    for (final folder in <String>['ps2', 'ps3', 'gc', 'wii', 'ports', 'switch', 'mame']) {
      expect(LibretroCoreCatalog.handles(folder), isFalse, reason: folder);
    }
  });

  test('every bound core is described and packaged', () {
    for (final binding in LibretroCoreCatalog.systems.values) {
      for (final id in <String>[binding.coreId, ...binding.alternatives]) {
        expect(LibretroCoreCatalog.cores.containsKey(id), isTrue, reason: id);
        expect(packaged, contains(id), reason: id);
      }
    }
    for (final id in LibretroCoreCatalog.cores.keys) {
      expect(packaged, contains(id), reason: id);
      expect(RegExp(r'^[a-z0-9_]+$').hasMatch(id), isTrue, reason: id);
    }
  });

  test('RetroAchievements console ids agree with the system definitions', () {
    for (final entry in LibretroCoreCatalog.systems.entries) {
      final ids = systems[entry.key]!['system']['ids'];
      final declared = ids is Map ? ids['retroachievements'] : null;
      if (declared is int) {
        expect(entry.value.achievementsConsoleId, declared, reason: entry.key);
      }
    }
  });

  test('import accepts the core formats and zip archives', () {
    expect(LibretroCoreCatalog.importExtensionsFor('snes'), containsAll(<String>['sfc', 'smc', 'zip']));
    expect(LibretroCoreCatalog.importExtensionsFor('gba'), containsAll(<String>['gba', 'zip']));
    expect(LibretroCoreCatalog.importExtensionsFor('psp'), containsAll(<String>['iso', 'cso']));
    expect(LibretroCoreCatalog.importExtensionsFor('unknown'), <String>{'zip'});
  });

  test('default core comes first, alternatives follow', () {
    expect(LibretroCoreCatalog.coresFor('md').map((core) => core.id).toList(),
        <String>['genesis_plus_gx', 'genesis_plus_gx_wide', 'picodrive']);
    expect(LibretroCoreCatalog.coresFor('ps1').first.biosAnyOf, isNotEmpty);
    expect(LibretroCoreCatalog.coresFor('3ds').single.preferredHardwareContext,
        LibretroHardwareContext.vulkan);
  });

  test('cores that generate machine code fall back to interpreters without JIT', () {
    final cores = LibretroCoreCatalog.cores;
    expect(cores['azahar']!.noJitOverrides, <String, String>{
      'citra_use_cpu_jit': 'disabled',
      'citra_use_shader_jit': 'disabled',
    });
    expect(cores['mupen64plus_next']!.noJitOverrides,
        <String, String>{'mupen64plus-cpucore': 'cached_interpreter'});
    expect(cores['ppsspp']!.noJitOverrides, <String, String>{'ppsspp_cpu_core': 'IR JIT'});
    expect(cores['desmume']!.noJitOverrides, <String, String>{'desmume_cpu_mode': 'interpreter'});
  });
}
