import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../repositories/emulator_repository.dart';
import '../repositories/system_repository.dart';
import 'retroarch_core_catalog.dart';

/// User choices are separate from the downloaded emulator database and its
/// foreign keys, so a catalogue refresh cannot overwrite an embedded choice.
abstract final class RetroArchCorePreferences {
  static String _systemKey(String folder) =>
      'retroarch_embedded_core_v1:${RetroArchCoreCatalog.normalizeSystem(folder)}';

  static String _gameKey(String folder, String romname) =>
      'retroarch_embedded_game_core_v1:'
      '${base64Url.encode(utf8.encode(jsonEncode([RetroArchCoreCatalog.normalizeSystem(folder), romname])))}';

  static Future<String?> systemCoreOverride(String folder) async =>
      (await SharedPreferences.getInstance()).getString(_systemKey(folder));

  /// Read the existing SQL choice without rewriting it or its foreign keys.
  static Future<String?> readLegacyCoreIdentifier(String folder) async {
    final system = await SystemRepository.getSystemByFolderName(
      RetroArchCoreCatalog.normalizeSystem(folder),
    );
    if (system?.id == null) return null;
    final emulator = await EmulatorRepository.getDefaultEmulatorForSystem(
      system!.id!,
    );
    if (emulator == null || emulator.isStandalone) return null;
    return emulator.coreFilename;
  }

  static Future<RetroArchCoreDescriptor> preferredCore(
    String folder, {
    Future<String?> Function(String folder)? readLegacyCore,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_systemKey(folder));
    if (saved == null) {
      final reader =
          readLegacyCore ?? (Platform.isIOS ? readLegacyCoreIdentifier : null);
      final legacy = reader == null ? null : await reader(folder);
      return RetroArchCoreCatalog.findCore(folder, legacy) ??
          RetroArchCoreCatalog.defaultCore(folder);
    }
    final core = RetroArchCoreCatalog.findCore(folder, saved);
    if (core == null) throw StateError('RETROARCH_UNSUPPORTED_CORE: $saved');
    return core;
  }

  static Future<void> setPreferredCore(String folder, String identifier) async {
    final core = RetroArchCoreCatalog.findCore(folder, identifier);
    if (core == null) throw ArgumentError.value(identifier, 'identifier');
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_systemKey(folder), core.identifier)) {
      await prefs.reload();
      throw StateError('RETROARCH_PREFERENCE_WRITE_FAILED');
    }
  }

  static Future<String?> gameCoreOverride(
    String folder,
    String romname,
  ) async => (await SharedPreferences.getInstance()).getString(
    _gameKey(folder, romname),
  );

  static Future<void> setGameCoreOverride(
    String folder,
    String romname,
    String? identifier,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (identifier == null) {
      // Empty means an explicit choice of the system default. Absence means
      // no new choice, allowing a valid legacy per-game preference to migrate.
      if (!await prefs.setString(_gameKey(folder, romname), '')) {
        await prefs.reload();
        throw StateError('RETROARCH_PREFERENCE_WRITE_FAILED');
      }
      return;
    }
    final core = RetroArchCoreCatalog.findCore(folder, identifier);
    if (core == null) throw ArgumentError.value(identifier, 'identifier');
    if (!await prefs.setString(_gameKey(folder, romname), core.identifier)) {
      await prefs.reload();
      throw StateError('RETROARCH_PREFERENCE_WRITE_FAILED');
    }
  }
}
