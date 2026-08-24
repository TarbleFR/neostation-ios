import 'dart:io';
import 'package:crypto/crypto.dart';
import 'retro_achievements_hash_strategy.dart';

class DefaultMd5HashStrategy implements RetroAchievementsHashStrategy {
  @override
  Future<String?> calculateHash(String filePath) async {
    try {
      final bytes = await File(filePath).readAsBytes();
      final digest = md5.convert(bytes);
      return digest.toString().toLowerCase();
    } catch (e) {
      return null;
    }
  }
}
