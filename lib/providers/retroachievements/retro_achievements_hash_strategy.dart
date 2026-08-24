import 'dart:async';

/// Base interface for calculating RetroAchievements hashes.
abstract class RetroAchievementsHashStrategy {
  /// Calculates the appropriate RetroAchievements hash for a given ROM file.
  Future<String?> calculateHash(String filePath);
}
