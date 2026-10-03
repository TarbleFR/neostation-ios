import '../models/core_emulator_model.dart';
import '../repositories/emulator_repository.dart';
import 'logger_service.dart';
import 'retroarch_core_catalog.dart';
import 'retroarch_core_preferences.dart';
import 'retroarch_internal_service.dart';

/// Resolves old SQL per-game identifiers without changing their foreign keys.
/// New per-game choices, including an explicit system default, take priority.
abstract final class RetroArchGameCoreSelection {
  static Future<RetroArchCoreDescriptor> resolve({
    required String systemFolderName,
    required String romname,
    String? systemId,
    String? legacyEmulatorId,
    String? legacyCoreId,
    Future<List<CoreEmulatorModel>> Function(String systemId)?
    readLegacyEmulators,
  }) async {
    final saved = await RetroArchCorePreferences.gameCoreOverride(
      systemFolderName,
      romname,
    );
    final resolvedLegacyCore = saved == null
        ? await resolveLegacyCoreIdentifier(
            systemFolderName: systemFolderName,
            systemId: systemId,
            legacyEmulatorId: legacyEmulatorId,
            legacyCoreId: legacyCoreId,
            readLegacyEmulators: readLegacyEmulators,
          )
        : null;
    return RetroArchInternalService.resolveCore(
      systemFolderName: systemFolderName,
      romname: romname,
      legacyCoreId: resolvedLegacyCore,
    );
  }

  /// A nullable legacy override for the settings UI. Absence stays null,
  /// allowing the UI to distinguish it from a proposed system default.
  /// Callers must apply saved overrides and the explicit-default sentinel first.
  static Future<String?> resolveLegacyCoreIdentifier({
    required String systemFolderName,
    String? systemId,
    String? legacyEmulatorId,
    String? legacyCoreId,
    Future<List<CoreEmulatorModel>> Function(String systemId)?
    readLegacyEmulators,
  }) async {
    final direct = RetroArchCoreCatalog.findCore(
      systemFolderName,
      legacyEmulatorId,
    );
    if (direct != null) return direct.identifier;
    if (systemId != null && legacyEmulatorId != null) {
      try {
        final emulators =
            await (readLegacyEmulators ??
                EmulatorRepository.getEmulatorsForSystemCurrentOs)(systemId);
        for (final emulator in emulators) {
          if (emulator.systemId != systemId ||
              emulator.uniqueId != legacyEmulatorId ||
              emulator.isStandalone) {
            continue;
          }
          final compatible = RetroArchCoreCatalog.findCore(
            systemFolderName,
            emulator.coreFilename,
          );
          if (compatible != null) {
            return compatible.identifier;
          }
        }
      } catch (error) {
        // An obsolete SQL entry is not a valid per-game override.
        LoggerService.instance.w(
          'Could not read legacy RetroArch core: $error',
        );
      }
    }
    return RetroArchCoreCatalog.findCore(
      systemFolderName,
      legacyCoreId,
    )?.identifier;
  }
}
