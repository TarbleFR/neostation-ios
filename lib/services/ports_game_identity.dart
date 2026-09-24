import 'dart:io';

import 'dusklight_game_identity.dart';
import 'kartpad_internal_service.dart';

/// Canonical identity for a title owned by NeoStation's Ports playlist.
///
/// The playlist is shared, but scraping must use the source console/game
/// identity of each embedded port rather than treating every title as
/// Dusklight/Twilight Princess.
class PortGameIdentity {
  const PortGameIdentity({
    required this.discId,
    required this.title,
    required this.displayTitle,
    required this.screenScraperSystemId,
  });

  final String discId;
  final String title;
  final String displayTitle;
  final int screenScraperSystemId;

  static Future<PortGameIdentity?> read(String gamePath) async {
    final dusklight = await DusklightGameIdentity.read(gamePath);
    if (dusklight != null) {
      return PortGameIdentity(
        discId: dusklight.discId,
        title: DusklightGameIdentity.title,
        displayTitle: DusklightGameIdentity.displayTitle,
        screenScraperSystemId: dusklight.screenScraperSystemId,
      );
    }

    if (!await KartPadInternalService.ownsGamePath(gamePath)) return null;
    final file = File(gamePath);
    if (!await file.exists()) return null;
    final kartPad = await KartPadInternalService.inspectGameFile(file);
    if (kartPad == null ||
        kartPad.gameId != KartPadInternalService.supportedDiscId) {
      return null;
    }
    return const PortGameIdentity(
      discId: KartPadInternalService.supportedDiscId,
      title: KartPadInternalService.displayTitle,
      displayTitle: KartPadInternalService.displayTitle,
      screenScraperSystemId: 16,
    );
  }
}
