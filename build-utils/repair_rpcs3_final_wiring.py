#!/usr/bin/env python3
from __future__ import annotations

import subprocess
from pathlib import Path


def main_text(path: str) -> str:
    return subprocess.check_output(
        ['git', 'show', f'origin/main:{path}'], text=True
    )


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one match, found {count}')
    return text.replace(old, new, 1)


def remove_region(text: str, start_marker: str, end_marker: str, label: str) -> str:
    start = text.find(start_marker)
    if start < 0:
        raise SystemExit(f'{label}: start marker missing')
    end = text.find(end_marker, start)
    if end < 0:
        raise SystemExit(f'{label}: end marker missing')
    return text[:start] + text[end:]


def rebuild_library_service() -> None:
    path = 'lib/services/rpcs3_library_service.dart'
    text = main_text(path)
    text = text.replace(
        "import 'package:external_folder_access/external_folder_access.dart';\n",
        '',
    )
    text = text.replace(
        "/// Imports the game list exposed by the unofficial RPCS3 iOS port.\n///\n/// RPCS3 exposes its persistent directory through Files at:\n/// `On My iPhone/iPad > RPCS3 > Data`.\n///\n/// The iOS build does not currently expose a library-export URL scheme, so\n/// NeoStation bookmarks that Data directory and mirrors RPCS3's own discovery\n/// rules. Metadata comes from `PARAM.SFO` under:\n",
        "/// Imports the game list owned by NeoStation's embedded RPCS3 Core.\n///\n/// The persistent PS3 data root is private NeoStation Application Support at\n/// `NeoStation/RPCS3/Data`. Metadata comes from `PARAM.SFO` under:\n",
    )
    text = text.replace(
        "/// Imported rows intentionally use an internal `rpcs3-library://` URI. They are\n/// display-only until RPCS3 publishes a supported direct-game deeplink.\n",
        "/// Imported rows use the existing internal `rpcs3-library://` URI. Launching\n/// resolves the title ID and boots it directly through the embedded RPCS3 Core.\n",
    )

    start = '  /// Restores the security-scoped bookmark and the last lightweight cache.\n  static Future<void> initialize() async {'
    end = '  /// Restores cached virtual PS3 rows'
    s = text.find(start)
    e = text.find(end, s)
    if s < 0 or e < 0:
        raise SystemExit('RPCS3 initialize markers missing')
    replacement = '''  /// Restores the last lightweight cache and creates NeoStation's private
  /// RPCS3 data root.
  static Future<void> initialize() async {
    await loadCachedLibrary();
    if (!Platform.isIOS) return;
    final support = await getApplicationSupportDirectory();
    final dataRoot = Directory(
      path.join(support.path, 'NeoStation', 'RPCS3', 'Data'),
    );
    await dataRoot.create(recursive: true);
    _linkedDataPath = path.normalize(dataRoot.path);
  }

'''
    text = text[:s] + replacement + text[e:]

    start = "  /// Lets the user select RPCS3's folder, bookmarks it, then performs a sync."
    end = '  /// Reads the currently linked RPCS3 Data directory and imports its PS3 rows.'
    s = text.find(start)
    e = text.find(end, s)
    if s < 0 or e < 0:
        raise SystemExit('RPCS3 link markers missing')
    replacement = '''  /// Compatibility entry point retained for callers that previously linked
  /// an external RPCS3 folder. The data root is now owned by NeoStation.
  static Future<Rpcs3SyncResult?> linkAndSync() async {
    if (!Platform.isIOS) return null;
    return syncInternalLibrary();
  }

  static Future<Rpcs3SyncResult> syncInternalLibrary() async {
    await initialize();
    return syncLinkedLibrary();
  }

'''
    text = text[:s] + replacement + text[e:]

    # Replace only the resolver function. The previous implementation removed
    # everything through _canReadDataRoot, which also deleted cache/catalog
    # helpers needed by startup and tests.
    start = '  static Future<String?> _resolveLinkedDataRoot() async {'
    end = '  static Future<void> _replaceCache(List<Rpcs3LibraryGame> games) async {'
    s = text.find(start)
    e = text.find(end, s)
    if s < 0 or e < 0:
        raise SystemExit('RPCS3 resolver markers missing')
    replacement = '''  static Future<String?> _resolveLinkedDataRoot() async {
    if (!Platform.isIOS) return linkedDataPath;
    if (linkedDataPath == null) await initialize();
    return linkedDataPath;
  }

'''
    text = text[:s] + replacement + text[e:]
    text = text.replace(
        "throw StateError('RPCS3 Data folder is not linked.');",
        "throw StateError('RPCS3 internal Data directory is unavailable.');",
    )
    Path(path).write_text(text)


def rebuild_directory_settings() -> None:
    path = 'lib/screens/settings_screen/new_settings_options/directories_settings_content.dart'
    text = main_text(path)
    text = text.replace(
        "import 'package:neostation/services/rpcs3_library_service.dart';\n",
        '',
    )
    text = text.replace(
        "import 'package:neostation/l10n/rpcs3_library_locale.dart';\n",
        '',
    )
    if '  Future<void> _linkRpcs3DataFolder() async {' in text:
        text = remove_region(
            text,
            '  Future<void> _linkRpcs3DataFolder() async {',
            '  List<Widget> _iosEmulatorCards(ThemeData theme) {',
            'RPCS3 external directory actions',
        )
    text = text.replace('      _buildIOSRpcs3Section(theme),\n', '')
    if '  Widget _buildIOSRpcs3Section(ThemeData theme) {' in text:
        text = remove_region(
            text,
            '  Widget _buildIOSRpcs3Section(ThemeData theme) {',
            '  Widget _buildIOSArmsx2Section(ThemeData theme) {',
            'RPCS3 external directory card',
        )
    Path(path).write_text(text)


def fix_file_picker_api() -> None:
    path = Path('lib/services/rpcs3_internal_service.dart')
    text = path.read_text()
    text = text.replace('FilePicker.platform', 'FilePicker.instance')
    path.write_text(text)


def main() -> None:
    subprocess.run(['git', 'fetch', 'origin', 'main'], check=True)
    rebuild_library_service()
    rebuild_directory_settings()
    fix_file_picker_api()
    print('RPCS3 final wiring repaired from clean main baselines.')


if __name__ == '__main__':
    main()
