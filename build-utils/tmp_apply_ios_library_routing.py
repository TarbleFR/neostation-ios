from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 match, found {count}")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# Manic EMU membership detection
# ---------------------------------------------------------------------------
p = Path("lib/services/manic_emu_library_service.dart")
s = p.read_text()
marker = "  static Future<bool> containsNintendo3dsGames(String dataFolder) async {\n"
method = """  /// Returns whether a ROM represented by [romPath] is actually present in the
  /// linked Manic EMU library.
  ///
  /// A row originating from Manic itself is identified by folder ownership.
  /// For a row originating from RetroArch, compare the filename stem against
  /// Manic's public Documents/Datas folder. This also handles RetroArch ZIP
  /// containers because Manic imports/extracts the contained ROM using the same
  /// title stem before computing its launch identifier.
  static Future<bool> hasGameForRomPath(
    String? linkedPath,
    String romPath,
  ) async {
    final root = linkedPath?.trim();
    final rom = romPath.trim();
    if (root == null || root.isEmpty || rom.isEmpty) return false;

    final normalizedRoot = path.normalize(root);
    final normalizedRom = path.normalize(rom);
    if (path.equals(normalizedRoot, normalizedRom) ||
        path.isWithin(normalizedRoot, normalizedRom)) {
      return true;
    }

    final targetStem = path.basenameWithoutExtension(normalizedRom).toLowerCase();
    if (targetStem.isEmpty) return false;

    final dataFolder = await resolveDataFolder(normalizedRoot);
    if (dataFolder != null) {
      try {
        await for (final entity in Directory(dataFolder).list(
          recursive: false,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          if (path.basenameWithoutExtension(entity.path).toLowerCase() ==
              targetStem) {
            return true;
          }
        }
      } catch (_) {
        // An unavailable security-scoped bookmark means the game cannot be
        // considered launchable from Manic for this session.
      }
    }

    // 3DS installs live outside Datas. Only inspect that tree for 3DS-family
    // extensions so ordinary ROM launches never pay for a recursive walk.
    final extension = path
        .extension(normalizedRom)
        .toLowerCase()
        .replaceFirst('.', '');
    if (!nintendo3dsExtensions.contains(extension)) return false;

    final documentsRoot = path.basename(normalizedRoot).toLowerCase() == 'datas'
        ? path.dirname(normalizedRoot)
        : normalizedRoot;
    final threeDsRoot = Directory(path.join(documentsRoot, '3DS'));
    if (!await threeDsRoot.exists()) return false;
    try {
      await for (final entity in threeDsRoot.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        if (path.basenameWithoutExtension(entity.path).toLowerCase() ==
            targetStem) {
          return true;
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

"""
s = replace_once(s, marker, method + marker, "insert Manic membership resolver")
p.write_text(s)


# ---------------------------------------------------------------------------
# Use true Manic membership in the launch router
# ---------------------------------------------------------------------------
p = Path("lib/services/game/game_launch_service.dart")
s = p.read_text()
s = replace_once(
    s,
    "import 'package:neostation/services/manic_emu_launch_service.dart';\n",
    "import 'package:neostation/services/manic_emu_launch_service.dart';\n"
    "import 'package:neostation/services/manic_emu_library_service.dart';\n",
    "add Manic library import",
)
old = """        final manicInstalled = await ManicEmuLaunchService.isInstalled();
        final manicFolder = ConfigService.linkedManicEmuFolderPath;
        final manicHasGame =
            manicInstalled &&
            manicFolder != null &&
            (path.equals(manicFolder, game.romPath!) ||
                path.isWithin(manicFolder, game.romPath!));
"""
new = """        final manicInstalled = await ManicEmuLaunchService.isInstalled();
        final manicHasGame =
            manicInstalled &&
            await ManicEmuLibraryService.hasGameForRomPath(
              ConfigService.linkedManicEmuFolderPath,
              game.romPath!,
            );
"""
s = replace_once(s, old, new, "replace Manic membership check")
p.write_text(s)


# ---------------------------------------------------------------------------
# Regression tests for cross-library matching
# ---------------------------------------------------------------------------
p = Path("test/manic_emu_library_service_test.dart")
s = p.read_text()
insert = """

  test('RetroArch path is recognized when same game exists in Manic Datas', () async {
    final temp = await Directory.systemTemp.createTemp('manic_membership_test_');
    addTearDown(() => temp.delete(recursive: true));
    final datas = Directory(path.join(temp.path, 'Datas'));
    await datas.create(recursive: true);
    await File(path.join(datas.path, 'Virtua Racing Deluxe.32x')).writeAsBytes([1]);

    expect(
      await ManicEmuLibraryService.hasGameForRomPath(
        temp.path,
        '/RetroArch/32x/Virtua Racing Deluxe.zip',
      ),
      isTrue,
    );
    expect(
      await ManicEmuLibraryService.hasGameForRomPath(
        temp.path,
        '/RetroArch/32x/WWF Raw.zip',
      ),
      isFalse,
    );
  });
"""
idx = s.rfind("\n}")
if idx < 0:
    raise SystemExit("Manic library test closing brace not found")
s = s[:idx] + insert + s[idx:]
p.write_text(s)
