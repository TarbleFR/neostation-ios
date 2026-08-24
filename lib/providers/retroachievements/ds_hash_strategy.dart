import '../../utils/optimized_md5_utils.dart';
import 'retro_achievements_hash_strategy.dart';

class DsHashStrategy implements RetroAchievementsHashStrategy {
  @override
  Future<String?> calculateHash(String filePath) async {
    return await OptimizedMd5Utils.calculateDsMd5(filePath);
  }
}
