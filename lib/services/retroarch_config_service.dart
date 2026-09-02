import 'dart:io';

import 'package:neostation/models/retroarch_config_model.dart';
import 'package:neostation/services/permission_service.dart';

import '../repositories/emulator_repository.dart';

import 'package:neostation/services/config_service.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/foundation.dart';
import 'package:neostation/services/logger_service.dart';

/// Service responsible for discovering, parsing, and resolving RetroArch
/// configuration settings across all supported platforms.
///
/// Locates `retroarch.cfg` by checking system-specific default paths and the
/// local application database. Resolves key directories for system files (BIOS),
/// save files, and save states, handling relative paths and platform-specific
/// environment variables.
class RetroArchConfigService {
  static final RetroArchConfigService _instance =
      RetroArchConfigService._internal();
  factory RetroArchConfigService() => _instance;
  RetroArchConfigService._internal();

  static final _log = LoggerService.instance;

  /// In-memory cache of the last successfully resolved configuration.
  RetroArchConfig? _cachedConfig;

  /// Attempts to locate the `retroarch.cfg` file on Android by checking
  /// standard package data directories.
  Future<String?> detectAndroidConfigPath() async {
    if (!Platform.isAndroid) return null;

    if (!await PermissionService.hasStoragePermissions()) {
      debugPrint('Missing storage permissions to detect RetroArch config');
      return null;
    }

    final possiblePaths = [
      '/storage/emulated/0/Android/data/com.retroarch/files/retroarch.cfg',
      '/storage/emulated/0/Android/data/com.retroarch.aarch64/files/retroarch.cfg',
      '/storage/emulated/0/Android/data/com.retroarch.ra32/files/retroarch.cfg',
    ];

    for (final p in possiblePaths) {
      if (await File(p).exists()) {
        return p;
      }
    }

    return null;
  }

  /// Parses the `retroarch.cfg` file and extracts directory configurations.
  ///
  /// Targets `system_directory`, `savefile_directory`, and `savestate_directory`.
  Future<RetroArchConfig> parseConfig(String configPath) async {
    final file = File(configPath);
    if (!await file.exists()) {
      throw Exception('RetroArch config file not found at $configPath');
    }

    String? systemDir;
    String? saveDir;
    String? stateDir;

    try {
      final lines = await file.readAsLines();

      for (final line in lines) {
        final timmedLine = line.trim();
        if (timmedLine.isEmpty || timmedLine.startsWith('#')) continue;

        if (timmedLine.startsWith('system_directory')) {
          systemDir = _extractValue(timmedLine);
        } else if (timmedLine.startsWith('savefile_directory')) {
          saveDir = _extractValue(timmedLine);
        } else if (timmedLine.startsWith('savestate_directory')) {
          stateDir = _extractValue(timmedLine);
        }
      }
    } catch (e) {
      _log.e('Error parsing RetroArch config: $e');
      rethrow;
    }

    final resolvedConfig = RetroArchConfig(
      configPath: configPath,
      systemDirectory: _normalizePath(systemDir, configPath),
      savefileDirectory: _normalizePath(saveDir, configPath),
      savestateDirectory: _normalizePath(stateDir, configPath),
    );

    return resolvedConfig;
  }

  /// Extracts the configuration value from a line, stripping quotes and whitespace.
  String? _extractValue(String line) {
    if (!line.contains('=')) return null;

    final parts = line.split('=');
    if (parts.length < 2) return null;

    var value = parts[1].trim();

    if (value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    } else if (value.startsWith("'") && value.endsWith("'")) {
      value = value.substring(1, value.length - 1);
    }

    if (value == 'default' || value.isEmpty) return null;

    return value;
  }

  /// Normalizes a directory path string.
  ///
  /// Handles home directory expansion (`~`) and Windows-specific relative paths
  /// (`:\` or `:/`).
  String? _normalizePath(String? dirPath, String configPath) {
    if (dirPath == null) return null;

    var normalized = dirPath;

    if ((Platform.isMacOS || Platform.isLinux) && normalized.startsWith('~')) {
      final home = ConfigService.getRealHomePath();
      normalized = normalized.replaceFirst('~', home);
    }

    if (normalized.startsWith(':\\') || normalized.startsWith(':/')) {
      final parentDir = File(configPath).parent.path;
      return path.join(parentDir, normalized.substring(2));
    }

    if (normalized == 'default') return null;

    return normalized;
  }

  /// Resolves RetroArch directories from the security-scoped folder linked
  /// by NeoStation on iOS. The bookmark itself is restored in main.dart before
  /// providers are created, so filesystem access is already active here.
  Future<RetroArchConfig?> _getIOSLinkedConfig() async {
    if (!Platform.isIOS) return null;

    String? linkedRoot = ConfigService.linkedExternalFolderPath?.trim();

    String? normalizeRetroArchRoot(String? raw) {
      if (raw == null || raw.trim().isEmpty) return null;
      final original = raw.trim();
      var current = Directory(original);
      for (var depth = 0; depth < 6; depth++) {
        final hasCfg =
            File(path.join(current.path, 'retroarch.cfg')).existsSync() ||
            File(path.join(current.path, 'config', 'retroarch.cfg')).existsSync();
        final hasSaves = Directory(path.join(current.path, 'saves')).existsSync();
        final hasStates = Directory(path.join(current.path, 'states')).existsSync();
        final hasPlaylists =
            Directory(path.join(current.path, 'playlists')).existsSync();
        if (hasCfg ||
            (hasSaves && hasStates) ||
            (hasPlaylists && (hasSaves || hasStates))) {
          return current.path;
        }
        final parent = current.parent;
        if (parent.path == current.path) break;
        current = parent;
      }
      return original;
    }

    final normalizedRoot = normalizeRetroArchRoot(linkedRoot);
    if (normalizedRoot != null && normalizedRoot != linkedRoot) {
      _log.i('NeoSync normalized RetroArch root: $linkedRoot -> $normalizedRoot');
      linkedRoot = normalizedRoot;
      ConfigService.linkedExternalFolderPath = normalizedRoot;
    }

    if (linkedRoot == null || linkedRoot.isEmpty) {
      _log.w(
        'iOS RetroArch folder is not linked; NeoSync local paths unavailable',
      );
      return null;
    }

    final activeRoot = linkedRoot;

    final root = Directory(activeRoot);
    if (!await root.exists()) {
      _log.w('iOS linked RetroArch folder no longer exists: $activeRoot');
      return null;
    }

    String? configPath;
    final configCandidates = <String>[
      path.join(activeRoot, 'retroarch.cfg'),
      path.join(activeRoot, 'config', 'retroarch.cfg'),
      path.join(activeRoot, 'RetroArch', 'retroarch.cfg'),
    ];
    for (final candidate in configCandidates) {
      if (File(candidate).existsSync()) {
        configPath = candidate;
        break;
      }
    }

    if (configPath == null) {
      try {
        for (final child
            in root.listSync(followLinks: false).whereType<Directory>()) {
          final candidate = path.join(child.path, 'retroarch.cfg');
          if (File(candidate).existsSync()) {
            configPath = candidate;
            break;
          }
        }
      } catch (e) {
        _log.w(
          'Could not inspect linked RetroArch folder for retroarch.cfg: $e',
        );
      }
    }

    RetroArchConfig? parsed;
    if (configPath != null) {
      try {
        parsed = await parseConfig(configPath);
      } catch (e) {
        _log.w('Could not parse linked iOS RetroArch config: $e');
      }
    }

    String resolveDirectory(String logicalName, String? configured) {
      if (configured != null &&
          configured.isNotEmpty &&
          Directory(configured).existsSync()) {
        return configured;
      }

      final names = <String>{logicalName.toLowerCase()};
      if (configured != null && configured.isNotEmpty) {
        names.add(path.basename(configured).toLowerCase());
      }

      final candidates = <String>[
        for (final name in names) path.join(activeRoot, name),
        for (final name in names) path.join(activeRoot, 'RetroArch', name),
      ];
      for (final candidate in candidates) {
        if (Directory(candidate).existsSync()) return candidate;
      }

      try {
        for (final child
            in root.listSync(followLinks: false).whereType<Directory>()) {
          if (names.contains(path.basename(child.path).toLowerCase())) {
            return child.path;
          }
        }
      } catch (_) {}

      // Downloads stay inside the bookmarked RetroArch folder even if the
      // directory has not been created by RetroArch yet.
      return path.join(activeRoot, logicalName);
    }

    final resolved = RetroArchConfig(
      configPath: configPath ?? '',
      systemDirectory: resolveDirectory('system', parsed?.systemDirectory),
      savefileDirectory: resolveDirectory('saves', parsed?.savefileDirectory),
      savestateDirectory: resolveDirectory(
        'states',
        parsed?.savestateDirectory,
      ),
    );
    _log.i(
      'iOS RetroArch paths resolved for NeoSync: '
      'saves=${resolved.savefileDirectory}, states=${resolved.savestateDirectory}',
    );
    return resolved;
  }

  /// Returns the merged configuration by discovering the platform's standard
  /// config path and applying defaults for missing fields.
  ///
  /// Uses heuristics to find the installation directory based on user emulator
  /// settings in the local database.
  Future<RetroArchConfig> getMergedConfig({bool forceRefresh = false}) async {
    if (_cachedConfig != null && !forceRefresh) {
      return _cachedConfig!;
    }

    if (Platform.isIOS) {
      final iosConfig = await _getIOSLinkedConfig();
      if (iosConfig != null) {
        _cachedConfig = iosConfig;
        return iosConfig;
      }
      return RetroArchConfig(
        configPath: '',
        systemDirectory: null,
        savefileDirectory: null,
        savestateDirectory: null,
      );
    }

    String? configPath;
    if (Platform.isAndroid) {
      configPath = await detectAndroidConfigPath();
    } else if (Platform.isWindows) {
      try {
        final exePath = await EmulatorRepository.getRetroArchExecutablePath();
        if (exePath != null) {
          final dir = path.dirname(exePath);
          final possibleCfg = path.join(dir, 'retroarch.cfg');
          if (await File(possibleCfg).exists()) {
            configPath = possibleCfg;
          } else {
            _log.w('retroarch.cfg not found at: $possibleCfg');
          }
        } else {
          _log.w('No RetroArch emulator path found in user_emulator_config!');
        }
      } catch (e) {
        _log.e('Error checking database for RetroArch: $e');
      }

      if (configPath == null) {
        final possiblePaths = [
          'C:\\RetroArch-Win64\\retroarch.cfg',
          'C:\\RetroArch\\retroarch.cfg',
          path.join(
            Platform.environment['APPDATA'] ?? '',
            'RetroArch',
            'retroarch.cfg',
          ),
        ];
        for (final p in possiblePaths) {
          if (await File(p).exists()) {
            configPath = p;
            break;
          }
        }
      }
    } else if (Platform.isLinux) {
      try {
        final exePath = await EmulatorRepository.getRetroArchExecutablePath();
        if (exePath != null) {
          final dir = path.dirname(exePath);
          final possibleCfg = path.join(dir, 'retroarch.cfg');
          if (await File(possibleCfg).exists()) {
            configPath = possibleCfg;
          }
        }
      } catch (e) {
        _log.e('Error checking database for RetroArch: $e');
      }

      if (configPath == null) {
        final home = ConfigService.getRealHomePath();
        final p = path.join(home, '.config', 'retroarch', 'retroarch.cfg');
        if (await File(p).exists()) {
          configPath = p;
        }
      }
    } else if (Platform.isMacOS) {
      try {
        final exePath = await EmulatorRepository.getRetroArchExecutablePath();
        if (exePath != null) {
          final dir = path.dirname(exePath);
          final possibleCfg = path.join(dir, 'retroarch.cfg');
          if (await File(possibleCfg).exists()) {
            configPath = possibleCfg;
          }
        }
      } catch (e) {
        _log.e('Error checking database for RetroArch: $e');
      }

      if (configPath == null) {
        final home = ConfigService.getRealHomePath();
        final possiblePaths = [
          path.join(
            home,
            'Library',
            'Application Support',
            'RetroArch',
            'config',
            'retroarch.cfg',
          ),
          path.join(home, 'Documents', 'RetroArch', 'retroarch.cfg'),
        ];
        for (final p in possiblePaths) {
          if (await File(p).exists()) {
            configPath = p;
            break;
          }
        }
      }
    }

    if (configPath != null) {
      try {
        _cachedConfig = await parseConfig(configPath);
        return _cachedConfig!;
      } catch (e) {
        _log.e('Error parsing RetroArch config at $configPath: $e');
      }
    }

    var finalConfig = RetroArchConfig(
      configPath: configPath ?? '',
      systemDirectory: null,
      savefileDirectory: null,
      savestateDirectory: null,
    );

    if (Platform.isMacOS) {
      final home = ConfigService.getRealHomePath();
      final defaultSaveDir = path.join(home, 'Documents', 'RetroArch');

      String? saveDir = finalConfig.savefileDirectory;
      if (saveDir == null || !Directory(saveDir).existsSync()) {
        saveDir = defaultSaveDir;
      }

      String? stateDir = finalConfig.savestateDirectory;
      if (stateDir == null || !Directory(stateDir).existsSync()) {
        stateDir = defaultSaveDir;
      }

      finalConfig = RetroArchConfig(
        configPath: finalConfig.configPath,
        systemDirectory: finalConfig.systemDirectory,
        savefileDirectory: saveDir,
        savestateDirectory: stateDir,
      );
    }

    if (Platform.isLinux) {
      final home = ConfigService.getRealHomePath();
      final defaultSaveDir = path.join(home, '.config', 'retroarch', 'saves');
      final defaultStateDir = path.join(home, '.config', 'retroarch', 'states');

      String? saveDir = finalConfig.savefileDirectory;
      if (saveDir == null || !Directory(saveDir).existsSync()) {
        saveDir = defaultSaveDir;
      }

      String? stateDir = finalConfig.savestateDirectory;
      if (stateDir == null || !Directory(stateDir).existsSync()) {
        stateDir = defaultStateDir;
      }

      finalConfig = RetroArchConfig(
        configPath: finalConfig.configPath,
        systemDirectory: finalConfig.systemDirectory,
        savefileDirectory: saveDir,
        savestateDirectory: stateDir,
      );
    }

    if (Platform.isAndroid) {
      const defaultSaveDir = '/storage/emulated/0/RetroArch/saves';
      const defaultStateDir = '/storage/emulated/0/RetroArch/states';

      String? saveDir = finalConfig.savefileDirectory;
      if (saveDir == null || !Directory(saveDir).existsSync()) {
        saveDir = defaultSaveDir;
      }

      String? stateDir = finalConfig.savestateDirectory;
      if (stateDir == null || !Directory(stateDir).existsSync()) {
        stateDir = defaultStateDir;
      }

      finalConfig = RetroArchConfig(
        configPath: finalConfig.configPath,
        systemDirectory: finalConfig.systemDirectory,
        savefileDirectory: saveDir,
        savestateDirectory: stateDir,
      );
    }

    return finalConfig;
  }

  /// Clears the in-memory configuration cache.
  void clearCache() {
    _cachedConfig = null;
  }

  /// Returns the expected absolute paths for the 4 Dreamcast VMU save files
  /// based on the provided RetroArch system directory.
  List<String> getDreamcastSavePaths(String systemDir) {
    final dcFolder = path.join(systemDir, 'dc');

    return [
      path.join(dcFolder, 'vmu_save_A1.bin'),
      path.join(dcFolder, 'vmu_save_B1.bin'),
      path.join(dcFolder, 'vmu_save_C1.bin'),
      path.join(dcFolder, 'vmu_save_D1.bin'),
    ];
  }
}
