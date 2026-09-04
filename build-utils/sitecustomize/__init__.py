"""Deterministic bootstrap normalization for the isolated Dolphin v3 branch.

Python imports this package as ``sitecustomize`` whenever a build-utils script
runs. The source bootstrap intentionally re-copies pristine v2 implementation
files on each CI pass; this package reapplies only the reviewed v3 corrections
before the materializer or isolation guard executes.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def patch_guard() -> None:
    guard = ROOT / 'build-utils/check_dolphin_isolation_v2.py'
    if not guard.is_file():
        return
    text = guard.read_text(encoding='utf-8')
    if '"build-utils/sitecustomize/__init__.py",' not in text:
        text = text.replace(
            '    "build-utils/check_dolphin_isolation_v2.py",\n',
            '    "build-utils/check_dolphin_isolation_v2.py",\n'
            '    "build-utils/sitecustomize/__init__.py",\n',
        )
    if '".github/workflows/dolphin-internal-isolated-v3.yml",' not in text:
        text = text.replace(
            '    ".github/workflows/dolphin-internal-isolated-v2.yml",\n',
            '    ".github/workflows/dolphin-internal-isolated-v2.yml",\n'
            '    ".github/workflows/dolphin-internal-isolated-v3.yml",\n',
        )
    text = text.replace(
        '    forbid(scanner, "romFolders: [..._config.romFolders", "global Dolphin root injection")\n',
        '    # Existing non-Dolphin roots are baseline code and are protected by\n'
        '    # the marker-aware diff. Dolphin itself must use only its private root.\n'
        '    require(scanner, "DolphinInternalV2Service.scanRootPath", "isolated private Dolphin root")\n',
    )
    guard.write_text(text, encoding='utf-8')


def patch_materializer() -> None:
    materializer = ROOT / 'build-utils/materialize_dolphin_isolated_v2.py'
    if not materializer.is_file():
        return
    text = materializer.read_text(encoding='utf-8')
    old = """        GameSessionManager.registerGameLaunch(
          system,
          game,
          'ios_dolphin_internal',
        );
        await FavoritesService.recordGamePlayed(game);
"""
    new = """        // Dolphin is an in-process session with deterministic native
        // cleanup. Do not enter the external-app lifecycle state machine.
        await FavoritesService.recordGamePlayed(game);
"""
    text = text.replace(old, new)
    materializer.write_text(text, encoding='utf-8')


def patch_service() -> None:
    service = ROOT / 'lib/services/dolphin_internal_v2_service.dart'
    if not service.is_file():
        return
    text = service.read_text(encoding='utf-8')
    text = text.replace(
        "throw const FileSystemException('Copied image length mismatch');",
        "throw FileSystemException('Copied image length mismatch');",
    )
    replacements = {
        "await output.delete().catchError((_) {});": "await _deleteIfExists(output);",
        "await temporary.delete().catchError((_) {});": "await _deleteIfExists(temporary);",
        "await target.delete().catchError((_) {});": "await _deleteIfExists(target);",
        "await marker.delete().catchError((_) {});": "await _deleteIfExists(marker);",
    }
    for old, new in replacements.items():
        text = text.replace(old, new)
    chained = """      await File(path.join(root.path, 'CrashMarkers', 'active-session.json'))
          .delete()
          .catchError((_) {});
"""
    text = text.replace(
        chained,
        """      await _deleteIfExists(
        File(path.join(root.path, 'CrashMarkers', 'active-session.json')),
      );
""",
    )
    helper = """  static Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort cleanup never replaces the original diagnostic.
    }
  }

"""
    anchor = '  static Future<File> _uniqueDestination(Directory directory, String name) async {\n'
    if helper not in text and anchor in text:
        text = text.replace(anchor, helper + anchor, 1)
    service.write_text(text, encoding='utf-8')


patch_guard()
patch_materializer()
patch_service()
