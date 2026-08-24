import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';
import '../models/game_model.dart';
import '../repositories/retro_achievements_repository.dart';
import '../repositories/system_repository.dart';
import '../utils/optimized_md5_utils.dart';
import 'archive_service.dart';

/// Service responsible for generating system-specific hashes required by
/// RetroAchievements (RA) for game identification.
///
/// RA uses different hashing algorithms depending on the platform (e.g., NES
/// hashes excluding headers, SNES hashes with specific offsets). This service
/// coordinates these algorithms, handles archive extraction, and offloads
/// processing to background isolates.
class RetroAchievementsHashService {
  /// Maximum file size permitted for hash generation (512 MB).
  static const int maxFileSizeBytes = 512 * 1024 * 1024;

  static final _log = LoggerService.instance;

  /// Generates the appropriate RA hash for a specific game if not already present.
  ///
  /// Checks local cache (SQLite) before attempting generation. Handles temporary
  /// extraction for compressed files and offloads the MD5 calculation to an
  /// isolate via [compute].
  static Future<String?> generateHashForGame(GameModel game) async {
    try {
      if (game.raHash != null && game.raHash!.isNotEmpty) {
        return game.raHash;
      }

      if (game.romPath == null) return null;

      if (!await OptimizedMd5Utils.fileExists(game.romPath!)) {
        return null;
      }

      final existingHash = await RetroAchievementsRepository.getRomRaHash(
        game.romPath!,
      );
      if (existingHash != null && existingHash.isNotEmpty) {
        return existingHash;
      }

      final fileSize = await OptimizedMd5Utils.getFileSize(game.romPath!);
      if (fileSize > maxFileSizeBytes) {
        return null;
      }

      String romPathToProcess = game.romPath!;
      final bool isArchive =
          (romPathToProcess.toLowerCase().endsWith('.zip') ||
              romPathToProcess.toLowerCase().endsWith('.7z')) &&
          !isArcadeSystem(game.systemFolderName);

      if (isArchive) {
        final extractedPath = await ArchiveService.extractRom(
          romPathToProcess,
          game.systemFolderName ?? 'unknown',
        );
        if (extractedPath != null) {
          romPathToProcess = extractedPath;
        } else {
          _log.w(
            'Failed to extract compressed file, aborting hash: ${game.name}',
          );
          return null;
        }
      }

      await Future.delayed(const Duration(milliseconds: 500));

      final isolateToken = RootIsolateToken.instance!;
      final hash = await compute(_generateHashForSystemIsolate, {
        'romPath': romPathToProcess,
        'systemFolderName': game.systemFolderName,
        'gameName': game.name,
        'token': isolateToken,
      });

      if (isArchive) {
        await ArchiveService.cleanupTempFolder(
          game.systemFolderName ?? 'unknown',
          game.romPath!,
        );
      }

      if (hash != null && hash.isNotEmpty) {
        await RetroAchievementsRepository.updateRomRaHash(game.romPath!, hash);

        if (game.systemFolderName != null) {
          final system = await SystemRepository.getSystemByFolderName(
            game.systemFolderName!,
          );
          if (system != null && system.raId != null) {
            await _lookupAndSaveGameIdByHash(hash, system.raId!, game);
          }
        }
      }

      return hash;
    } catch (e) {
      _log.e('Error generating hash for ${game.name}: $e');
      return null;
    }
  }

  /// Batch processes hashes for a list of games in the background.
  ///
  /// Skips games with existing hashes or those exceeding the size limit.
  static Future<int> processGamesHashesInBackground(
    List<GameModel> games,
  ) async {
    int hashesGenerated = 0;

    try {
      for (final game in games) {
        if (game.raHash != null && game.raHash!.isNotEmpty) {
          continue;
        }

        if (!await OptimizedMd5Utils.fileExists(game.romPath!)) {
          _log.w('File not found: ${game.romPath}');
          continue;
        }

        final fileSize = await OptimizedMd5Utils.getFileSize(game.romPath!);
        if (fileSize > maxFileSizeBytes) {
          continue;
        }

        String romPathToProcess = game.romPath!;
        final bool isArchive =
            (romPathToProcess.toLowerCase().endsWith('.zip') ||
                romPathToProcess.toLowerCase().endsWith('.7z')) &&
            !isArcadeSystem(game.systemFolderName);

        if (isArchive) {
          final extractedPath = await ArchiveService.extractRom(
            romPathToProcess,
            game.systemFolderName ?? 'unknown',
          );
          if (extractedPath != null) {
            romPathToProcess = extractedPath;
          } else {
            continue;
          }
        }

        String? hash;
        try {
          hash = await _generateHashForSystem(
            game,
            overrideRomPath: romPathToProcess,
          );
        } catch (e) {
          _log.e('Error generating hash for ${game.name}: $e');
        } finally {
          if (isArchive) {
            await ArchiveService.cleanupTempFolder(
              game.systemFolderName ?? 'unknown',
              game.romPath!,
            );
          }
        }

        if (hash == null) continue;

        if (hash.isNotEmpty) {
          await RetroAchievementsRepository.updateRomRaHash(
            game.romPath!,
            hash,
          );
          hashesGenerated++;
        }
      }
    } catch (e) {
      _log.e('Error in processGamesHashesInBackground: $e');
    }

    return hashesGenerated;
  }

  /// Determines if a specific system requires a non-standard hashing algorithm
  /// recognized by RetroAchievements.
  static bool hasSpecificHashGenerator(String? systemFolderName) {
    if (systemFolderName == null) return false;
    final system = systemFolderName.toLowerCase();

    return system == 'nes' ||
        system == 'fc' ||
        system == 'ds' ||
        system == 'snes' ||
        system == 'sfc' ||
        system == 'satellaview' ||
        system == 'arc' ||
        system == 'fbneo' ||
        system == 'neogeo' ||
        system == 'naomi' ||
        system == 'naomi2' ||
        system == 'naomigd' ||
        system == 'aw' ||
        system == 'cps1' ||
        system == 'cps2' ||
        system == 'cps3' ||
        system == 'mame' ||
        system == 'gb' ||
        system == 'gbc' ||
        system == 'gba' ||
        system == 'vb' ||
        system == 'ngp' ||
        system == 'ngpc' ||
        system == '32x' ||
        system == 'sms' ||
        system == 'mark3' ||
        system == 'wasm4' ||
        system == 'md' ||
        system == 'genesis' ||
        system == 'jag' ||
        system == 'ws' ||
        system == 'wsc' ||
        system == 'chf' ||
        system == 'vect' ||
        system == 'mo2' ||
        system == 'intv' ||
        system == 'cv' ||
        system == '2600' ||
        system == '7800' ||
        system == 'lynx' ||
        system == 'ard' ||
        system == 'n64' ||
        system == 'sg1k' ||
        system == 'duck' ||
        system == 'wsv' ||
        system == 'gg' ||
        system == 'mini';
  }

  /// Identifies if a system belongs to the Arcade category, where ROM archives
  /// (ZIPs) should not be extracted for hashing.
  static bool isArcadeSystem(String? systemFolderName) {
    if (systemFolderName == null) return false;
    final system = systemFolderName.toLowerCase();
    return system == 'arc' ||
        system == 'fbneo' ||
        system == 'neogeo' ||
        system == 'naomi' ||
        system == 'naomi2' ||
        system == 'naomigd' ||
        system == 'aw' ||
        system == 'cps1' ||
        system == 'cps2' ||
        system == 'cps3' ||
        system == 'mame';
  }

  /// Top-level function executed in a background isolate to compute system-specific hashes.
  static Future<String?> _generateHashForSystemIsolate(
    Map<String, dynamic> params,
  ) async {
    final token = params['token'] as RootIsolateToken?;
    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }

    final romPath = params['romPath'].toString();
    final systemFolderName = params['systemFolderName']?.toString();
    final systemFolder = systemFolderName?.toLowerCase() ?? '';

    try {
      String? hash;

      if (systemFolder == 'nes' || systemFolder == 'fc') {
        hash = await OptimizedMd5Utils.calculateNesMd5(romPath);
      } else if (systemFolder == 'ds') {
        hash = await OptimizedMd5Utils.calculateDsMd5(romPath);
      } else if (systemFolder == 'arc' ||
          systemFolder == 'fbneo' ||
          systemFolder == 'neogeo' ||
          systemFolder == 'naomi' ||
          systemFolder == 'naomi2' ||
          systemFolder == 'naomigd' ||
          systemFolder == 'aw' ||
          systemFolder == 'cps1' ||
          systemFolder == 'cps2' ||
          systemFolder == 'cps3' ||
          systemFolder == 'mame') {
        hash = OptimizedMd5Utils.calculateArcadeMd5(romPath);
      } else if (systemFolder == 'snes' ||
          systemFolder == 'sfc' ||
          systemFolder == 'satellaview') {
        hash = await OptimizedMd5Utils.calculateSnesMd5(romPath);
      } else if (systemFolder == '7800') {
        hash = await OptimizedMd5Utils.calculateAtari7800Md5(romPath);
      } else if (systemFolder == 'lynx') {
        hash = await OptimizedMd5Utils.calculateLynxMd5(romPath);
      } else if (systemFolder == 'ard') {
        hash = await OptimizedMd5Utils.calculateArduboyMd5(romPath);
      } else if (systemFolder == 'n64') {
        hash = await OptimizedMd5Utils.calculateN64Md5(romPath);
      } else {
        hash = await OptimizedMd5Utils.calculateFileMd5(romPath);
      }

      return hash;
    } catch (e) {
      _log.e('Error generating hash for system $systemFolder: $e');
      return null;
    }
  }

  /// Resolves the specific hashing algorithm for a system and executes it.
  static Future<String?> _generateHashForSystem(
    GameModel game, {
    String? overrideRomPath,
  }) async {
    final systemFolder = game.systemFolderName?.toLowerCase() ?? '';
    final romPath = overrideRomPath ?? game.romPath!;

    try {
      String? hash;

      if (systemFolder == 'nes' ||
          systemFolder == 'famicom' ||
          systemFolder == 'fds') {
        hash = await OptimizedMd5Utils.calculateNesMd5(romPath);
      } else if (systemFolder == 'ds') {
        hash = await OptimizedMd5Utils.calculateDsMd5(romPath);
      } else if (systemFolder == 'arc' ||
          systemFolder == 'fbneo' ||
          systemFolder == 'neogeo' ||
          systemFolder == 'mame') {
        hash = OptimizedMd5Utils.calculateArcadeMd5(romPath);
      } else if (systemFolder == 'snes' ||
          systemFolder == 'sfc' ||
          systemFolder == 'satellaview') {
        hash = await OptimizedMd5Utils.calculateSnesMd5(romPath);
      } else if (systemFolder == '7800') {
        hash = await OptimizedMd5Utils.calculateAtari7800Md5(romPath);
      } else if (systemFolder == 'lynx') {
        hash = await OptimizedMd5Utils.calculateLynxMd5(romPath);
      } else if (systemFolder == 'ard') {
        hash = await OptimizedMd5Utils.calculateArduboyMd5(romPath);
      } else if (systemFolder == 'n64') {
        hash = await OptimizedMd5Utils.calculateN64Md5(romPath);
      } else {
        hash = await OptimizedMd5Utils.calculateFileMd5(romPath);
      }

      final system = await SystemRepository.getSystemByFolderName(
        game.systemFolderName!,
      );
      if (system == null) return hash;
      final raId = system.raId;
      if (raId != null) {
        await _lookupAndSaveGameIdByHash(hash, raId, game);
      }

      return hash;
    } catch (e) {
      _log.e('Error generating hash for system $systemFolder: $e');
      return null;
    }
  }

  /// Searches for the RetroAchievements Game ID in the local database using the
  /// generated hash and updates the game metadata.
  static Future<void> _lookupAndSaveGameIdByHash(
    String raHash,
    String raConsoleId,
    GameModel game,
  ) async {
    try {
      final gameId = await RetroAchievementsRepository.getGameIdByHash(
        raHash,
        raConsoleId,
      );

      if (gameId != null) {
        await RetroAchievementsRepository.updateRomRaGameId(
          game.romPath!,
          gameId,
        );
      } else {
        _log.w('No game ID found in internal DB for RA hash: ${game.name}');
      }
    } catch (e) {
      _log.e('Error looking up game ID by hash: $e');
    }
  }
}
