from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 match, found {count}")
    return text.replace(old, new, 1)


# Pure routing rule: availability always wins. Primary is only a preference
# when both libraries actually contain the game.
p = Path("lib/services/ios_emulator_preference_service.dart")
s = p.read_text()
marker = "  /// Resolves the iOS library applications associated with a system's games.\n"
method = """  /// Chooses the iOS library app for one game from actual library availability.
  ///
  /// The primary emulator is a preference only when both libraries contain the
  /// game. It must never route a RetroArch-only game to Manic EMU, or vice versa.
  static IosLibraryEmulator? resolveLaunchEmulator({
    required IosLibraryEmulator primary,
    required bool retroArchHasGame,
    required bool manicEmuHasGame,
  }) {
    if (retroArchHasGame && manicEmuHasGame) return primary;
    if (retroArchHasGame) return IosLibraryEmulator.retroArch;
    if (manicEmuHasGame) return IosLibraryEmulator.manicEmu;
    return null;
  }

"""
s = replace_once(s, marker, method + marker, "insert launch resolver")
p.write_text(s)


# Replace the former global-primary/per-game-prompt routing block.
p = Path("lib/services/game/game_launch_service.dart")
s = p.read_text()
start = s.index(
    "        // Multi-system iOS libraries: RetroArch and Manic EMU can coexist."
)
end = s.index(
    "        // Genuine one-tap launch via RetroArch's synced library and", start
)
new = """        // Multi-system iOS libraries: route by actual membership first.
        // The user's primary emulator is only a preference when BOTH libraries
        // contain this game. It is never a global override for every title.
        final retroArchHasGame =
            RetroArchLibraryService.hasGameForRomPath(game.romPath!);
        final manicInstalled = await ManicEmuLaunchService.isInstalled();
        final manicFolder = ConfigService.linkedManicEmuFolderPath;
        final manicHasGame =
            manicInstalled &&
            manicFolder != null &&
            (path.equals(manicFolder, game.romPath!) ||
                path.isWithin(manicFolder, game.romPath!));
        final primaryLibraryEmulator =
            await IosEmulatorPreferenceService.primary();
        final libraryEmulator =
            IosEmulatorPreferenceService.resolveLaunchEmulator(
              primary: primaryLibraryEmulator,
              retroArchHasGame: retroArchHasGame,
              manicEmuHasGame: manicHasGame,
            );

        if (libraryEmulator == IosLibraryEmulator.manicEmu) {
          final launched = await ManicEmuLaunchService.launchGame(
            game.romPath!,
          );
          if (launched) return GameLaunchResult.success();
          return GameLaunchResult.failure(
            AppLocale.failedToLaunchStandalone
                .getString(context)
                .replaceFirst('{name}', 'Manic EMU'),
            game.romPath,
          );
        }

"""
s = s[:start] + new + s[end:]
p.write_text(s)


# Regression tests for the exact desired routing matrix.
p = Path("test/ios_system_emulator_association_test.dart")
s = p.read_text()
insert = """
  group('per-game iOS launch routing', () {
    IosLibraryEmulator? route({
      required IosLibraryEmulator primary,
      required bool retroArch,
      required bool manic,
    }) => IosEmulatorPreferenceService.resolveLaunchEmulator(
      primary: primary,
      retroArchHasGame: retroArch,
      manicEmuHasGame: manic,
    );

    test('RetroArch-only game ignores Manic primary preference', () {
      expect(
        route(
          primary: IosLibraryEmulator.manicEmu,
          retroArch: true,
          manic: false,
        ),
        IosLibraryEmulator.retroArch,
      );
    });

    test('Manic-only game ignores RetroArch primary preference', () {
      expect(
        route(
          primary: IosLibraryEmulator.retroArch,
          retroArch: false,
          manic: true,
        ),
        IosLibraryEmulator.manicEmu,
      );
    });

    test('game in both libraries uses the primary preference', () {
      expect(
        route(
          primary: IosLibraryEmulator.manicEmu,
          retroArch: true,
          manic: true,
        ),
        IosLibraryEmulator.manicEmu,
      );
      expect(
        route(
          primary: IosLibraryEmulator.retroArch,
          retroArch: true,
          manic: true,
        ),
        IosLibraryEmulator.retroArch,
      );
    });

    test('game in neither library does not force a library emulator', () {
      expect(
        route(
          primary: IosLibraryEmulator.manicEmu,
          retroArch: false,
          manic: false,
        ),
        isNull,
      );
    });
  });
"""
idx = s.rfind("\n}")
if idx < 0:
    raise SystemExit("test file closing brace not found")
s = s[:idx] + insert + s[idx:]
p.write_text(s)


# Build number 160 for this behavior change.
p = Path("pubspec.yaml")
s = p.read_text()
s = replace_once(s, "version: 1.0.0+159", "version: 1.0.0+160", "build number")
p.write_text(s)
