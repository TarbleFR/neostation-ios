import 'dart:io';
import '../../utils/optimized_md5_utils.dart';
import 'retro_achievements_hash_strategy.dart';

class ConsoleLookupHashStrategy implements RetroAchievementsHashStrategy {
  final String consoleName;

  ConsoleLookupHashStrategy(this.consoleName);

  @override
  Future<String?> calculateHash(String filePath) async {
    final file = File(filePath);
    final filename = file.uri.pathSegments.last;
    final filenameWithoutExtension = filename.replaceAll(
      RegExp(r'\.[^.]+$'),
      '',
    );

    final parentSegments = file.parent.uri.pathSegments;
    final folderName = parentSegments.isNotEmpty
        ? parentSegments.last.replaceAll('/', '')
        : '';

    final emulatorName = 'flycast'; // Matching existing hardcoded logic

    return await OptimizedMd5Utils.lookupSystemHashAndSave(
      filenameWithoutExtension: filenameWithoutExtension,
      systemFolderName: folderName,
      romPath: filePath,
      emulatorName: emulatorName,
      consoleName: consoleName,
    );
  }
}
