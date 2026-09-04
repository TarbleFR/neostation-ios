import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<_SeedSystem> systems;

  setUpAll(() async {
    final directory = Directory('assets/systems');
    final files = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList();

    systems = [];
    for (final file in files) {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final emulators = (json['emulators'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (raw) => _SeedEmulator(
              raw['unique_id']?.toString() ?? '',
              raw['default_standalone'] == true,
              raw['default_core'] == true,
              Map<String, dynamic>.from(raw['platforms'] as Map? ?? const {}),
            ),
          )
          .toList();
      systems.add(_SeedSystem(file.uri.pathSegments.last, emulators));
    }
  });

  test('every system ships at most one default_standalone emulator', () {
    final offenders = <String>[];
    for (final system in systems) {
      final defaults = system.emulators.where((e) => e.isDefaultStandalone);
      if (defaults.length > 1) {
        offenders.add(
          '${system.name}: ${defaults.map((e) => e.uniqueId).join(', ')}',
        );
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('per (system, os) at most one default_standalone emulator is offered', () {
    final offenders = <String>[];
    for (final system in systems) {
      final counts = <String, int>{};
      for (final emulator in system.emulators.where((e) => e.isDefaultStandalone)) {
        for (final os in emulator.platforms.keys) {
          counts[os] = (counts[os] ?? 0) + 1;
        }
      }
      for (final entry in counts.entries) {
        if (entry.value > 1) {
          offenders.add('${system.name}/${entry.key}: ${entry.value} defaults');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('every default_core emulator is a RetroArch definition', () {
    final offenders = <String>[];
    for (final system in systems) {
      for (final emulator in system.emulators.where((e) => e.isDefaultCore)) {
        final uid = emulator.uniqueId.toLowerCase();
        if (!uid.contains('.ra.') &&
            !uid.contains('.ra32.') &&
            !uid.contains('.ra64.')) {
          offenders.add('${system.name}: ${emulator.uniqueId}');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('all default_core entries in a system name the same libretro core', () {
    final offenders = <String>[];
    for (final system in systems) {
      final defaultCoreIds = system.emulators
          .where((e) => e.isDefaultCore)
          .map((e) => e.uniqueId)
          .toList();
      if (defaultCoreIds.length <= 1) continue;

      final coreNames = defaultCoreIds
          .map((uid) => uid.split('.').last)
          .toSet();
      if (coreNames.length > 1) {
        offenders.add('${system.name}: ${defaultCoreIds.join(', ')}');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('every iOS emulator declares a non-empty url_scheme', () {
    final offenders = <String>[];
    for (final system in systems) {
      for (final emulator in system.emulators) {
        final ios = emulator.platforms['ios'];
        if (ios is! Map) continue;
        final scheme = ios['url_scheme']?.toString().trim() ?? '';
        if (scheme.isEmpty) {
          offenders.add('${system.name}: ${emulator.uniqueId}');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('PS2 exposes ARMSX2 on iOS through the armsx2 URL scheme', () {
    final ps2 = systems.firstWhere((s) => s.name == 'ps2.json');
    final armsx2 = ps2.emulators.firstWhere(
      (e) => e.uniqueId == 'ps2.ios.armsx2',
    );
    final ios = Map<String, dynamic>.from(armsx2.platforms['ios'] as Map);

    expect(ios['url_scheme'], 'armsx2');
  });

  test('Switch exposes MeloNX on iOS through the melonx URL scheme', () {
    final switchSystem = systems.firstWhere((s) => s.name == 'switch.json');
    final melonx = switchSystem.emulators.firstWhere(
      (e) => e.uniqueId == 'switch.ios.melonx',
    );
    final ios = Map<String, dynamic>.from(melonx.platforms['ios'] as Map);

    expect(ios['url_scheme'], 'melonx');
  });

  test('systems with supported iOS RetroArch integration expose one generic app', () {
    final offenders = <String>[];

    for (final system in systems) {
      // PS2 deliberately uses ARMSX2 on iOS. GameCube and Wii deliberately use
      // NeoStation's embedded Dolphin engine on this isolated branch. Their
      // RetroArch/Dolphin definitions remain valid for Android and desktop,
      // but none of the three systems should seed a generic iOS RetroArch app.
      if (const {'ps2.json', 'gc.json', 'wii.json'}.contains(system.name)) {
        continue;
      }

      final hasRetroArchDefinition = system.emulators.any((e) {
        final uid = e.uniqueId.toLowerCase();
        final platformText = jsonEncode(e.platforms).toLowerCase();
        return uid.contains('.ra.') ||
            uid.contains('.ra32.') ||
            uid.contains('.ra64.') ||
            platformText.contains('retroarch');
      });
      if (!hasRetroArchDefinition) continue;

      final iosRetroArch = system.emulators.where((e) {
        final ios = e.platforms['ios'];
        return ios is Map &&
            ios['url_scheme']?.toString().toLowerCase() == 'retroarch';
      }).toList();

      if (iosRetroArch.length != 1) {
        offenders.add(
          '${system.name}: expected 1 generic iOS RetroArch entry, found ${iosRetroArch.length}',
        );
      }
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('the two systems fixed on this branch resolve to a single default', () {
    // Regression pins for the pair found on the AYN Thor.
    final switchSystem = systems.firstWhere((s) => s.name == 'switch.json');
    final xbox360 = systems.firstWhere((s) => s.name == 'xbox360.json');

    expect(
      switchSystem.emulators
          .where((e) => e.isDefaultStandalone)
          .map((e) => e.uniqueId),
      ['switch.dev.eden.eden_emulator'],
    );
    expect(
      xbox360.emulators
          .where((e) => e.isDefaultStandalone)
          .map((e) => e.uniqueId),
      ['xbox360.aenu.ax360e.free'],
    );
  });
}

class _SeedSystem {
  _SeedSystem(this.name, this.emulators);

  final String name;
  final List<_SeedEmulator> emulators;
}

class _SeedEmulator {
  _SeedEmulator(
    this.uniqueId,
    this.isDefaultStandalone,
    this.isDefaultCore,
    this.platforms,
  );

  final String uniqueId;
  final bool isDefaultStandalone;
  final bool isDefaultCore;
  final Map<String, dynamic> platforms;
}
