#!/usr/bin/env python3
"""Wire the embedded RPCS3 engine into NeoStation's existing PS3 UI/library.

This patch intentionally does not read or modify any Dolphin source file.
"""
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one match, found {count}')
    return text.replace(old, new, 1)


def replace_region(
    text: str,
    start_marker: str,
    end_marker: str,
    replacement: str,
    label: str,
) -> str:
    start = text.find(start_marker)
    if start < 0:
        raise SystemExit(f'{label}: start marker missing')
    end = text.find(end_marker, start)
    if end < 0:
        raise SystemExit(f'{label}: end marker missing')
    return text[:start] + replacement + text[end:]


# RPCS3 library data is now owned by NeoStation rather than bookmarked from a
# separately installed application container.
library_path = Path('lib/services/rpcs3_library_service.dart')
library = library_path.read_text()
library = library.replace(
    "import 'package:external_folder_access/external_folder_access.dart';\n",
    '',
)
library = library.replace(
    "/// Imports the game list exposed by the unofficial RPCS3 iOS port.\n///\n/// RPCS3 exposes its persistent directory through Files at:\n/// `On My iPhone/iPad > RPCS3 > Data`.\n///\n/// The iOS build does not currently expose a library-export URL scheme, so\n/// NeoStation bookmarks that Data directory and mirrors RPCS3's own discovery\n/// rules. Metadata comes from `PARAM.SFO` under:\n",
    "/// Imports the game list owned by NeoStation's embedded RPCS3 Core.\n///\n/// The persistent PS3 data root is private NeoStation Application Support at\n/// `NeoStation/RPCS3/Data`. Metadata comes from `PARAM.SFO` under:\n",
)
library = library.replace(
    "/// Imported rows intentionally use an internal `rpcs3-library://` URI. They are\n/// display-only until RPCS3 publishes a supported direct-game deeplink.\n",
    "/// Imported rows use the existing internal `rpcs3-library://` URI. Launching\n/// resolves the title ID and boots it directly through the embedded RPCS3 Core.\n",
)
library = replace_region(
    library,
    '  /// Restores the security-scoped bookmark and the last lightweight cache.\n  static Future<void> initialize() async {',
    '  /// Restores cached virtual PS3 rows',
    '''  /// Restores the last lightweight cache and creates NeoStation's private
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

''',
    'RPCS3 internal initialize',
)
library = replace_region(
    library,
    "  /// Lets the user select RPCS3's folder, bookmarks it, then performs a sync.",
    '  /// Reads the currently linked RPCS3 Data directory and imports its PS3 rows.',
    '''  /// Compatibility entry point retained for callers that previously linked
  /// an external RPCS3 folder. The data root is now owned by NeoStation.
  static Future<Rpcs3SyncResult?> linkAndSync() async {
    if (!Platform.isIOS) return null;
    return syncInternalLibrary();
  }

  static Future<Rpcs3SyncResult> syncInternalLibrary() async {
    await initialize();
    return syncLinkedLibrary();
  }

''',
    'RPCS3 external link retirement',
)
library = replace_region(
    library,
    '  static Future<String?> _resolveLinkedDataRoot() async {',
    '  static Future<bool> _canReadDataRoot(String dataRoot) async {',
    '''  static Future<String?> _resolveLinkedDataRoot() async {
    if (!Platform.isIOS) return linkedDataPath;
    if (linkedDataPath == null) await initialize();
    return linkedDataPath;
  }

''',
    'RPCS3 internal data root resolver',
)
library = library.replace(
    "throw StateError('RPCS3 Data folder is not linked.');",
    "throw StateError('RPCS3 internal Data directory is unavailable.');",
)
library_path.write_text(library)


# RPCS3 import actions belong directly to the PS3 library screen.
games_path = Path('lib/screens/game_screen/my_games_list.dart')
games = games_path.read_text()
if "rpcs3_internal_playlist_actions.dart" not in games:
    games = replace_once(
        games,
        "import 'package:neostation/services/dolphin_internal_v2_service.dart';\n",
        "import 'package:neostation/services/dolphin_internal_v2_service.dart';\n"
        "import 'package:neostation/widgets/rpcs3_internal_playlist_actions.dart';\n",
        'RPCS3 playlist import',
    )

rpcs3_actions = r'''            // RPCS3_INTERNAL_BEGIN: playlist_actions
            if (!_isGameLaunching &&
                Platform.isIOS &&
                widget.system.folderName.toLowerCase() == 'ps3')
              Positioned(
                top: 8.r,
                right: 10.r,
                child: SafeArea(
                  child: Material(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(12.r),
                    child: Rpcs3InternalPlaylistActions(
                      onInteractionChanged: (active) {
                        if (!mounted) return;
                        if (active) {
                          _gamepadNav.deactivate();
                        } else {
                          _gamepadNav.activate();
                        }
                      },
                      onLibraryChanged: () async {
                        if (!mounted) return;
                        await _loadGames();
                      },
                    ),
                  ),
                ),
              ),
            // RPCS3_INTERNAL_END: playlist_actions
'''
if 'RPCS3_INTERNAL_BEGIN: playlist_actions' not in games:
    games = replace_once(
        games,
        '            // DOLPHIN_ISOLATION_END: playlist_actions\n',
        '            // DOLPHIN_ISOLATION_END: playlist_actions\n' + rpcs3_actions,
        'RPCS3 playlist action block',
    )
games_path.write_text(games)


# Remove the obsolete RPCS3 external-directory UI. Other emulator directory
# cards remain unchanged.
settings_path = Path(
    'lib/screens/settings_screen/new_settings_options/directories_settings_content.dart'
)
settings = settings_path.read_text()
settings = settings.replace(
    "import 'package:neostation/services/rpcs3_library_service.dart';\n",
    '',
)
settings = settings.replace(
    "import 'package:neostation/l10n/rpcs3_library_locale.dart';\n",
    '',
)
if 'Future<void> _linkRpcs3DataFolder() async {' in settings:
    settings = replace_region(
        settings,
        '  Future<void> _linkRpcs3DataFolder() async {',
        '  List<Widget> _iosEmulatorCards(ThemeData theme) {',
        '  List<Widget> _iosEmulatorCards(ThemeData theme) {',
        'RPCS3 directory actions',
    )
settings = settings.replace('      _buildIOSRpcs3Section(theme),\n', '')
if 'Widget _buildIOSRpcs3Section(ThemeData theme) {' in settings:
    settings = replace_region(
        settings,
        '  Widget _buildIOSRpcs3Section(ThemeData theme) {',
        '  Widget _buildIOSArmsx2Section(ThemeData theme) {',
        '  Widget _buildIOSArmsx2Section(ThemeData theme) {',
        'RPCS3 directory card',
    )
settings_path.write_text(settings)


# The game launch path now describes an in-process RPCS3 session and surfaces
# the precise firmware/JIT/Core error produced by the internal service.
launch_path = Path('lib/services/game/game_launch_service.dart')
launch = launch_path.read_text().replace(
    "'ios_rpcs3_stikdebug'",
    "'ios_rpcs3_internal'",
)
old_failure = '''          return GameLaunchResult.failure(
            Rpcs3LibraryLocale.launchFailed(context),
            titleId,
          );'''
new_failure = '''          final internalError = Rpcs3LaunchService.lastError?.trim();
          return GameLaunchResult.failure(
            internalError != null && internalError.isNotEmpty
                ? internalError
                : Rpcs3LibraryLocale.launchFailed(context),
            titleId,
          );'''
if old_failure in launch:
    launch = replace_once(
        launch,
        old_failure,
        new_failure,
        'RPCS3 internal error surface',
    )
launch_path.write_text(launch)


# The extracted RPCS3 Core is a verified build input and must never be committed.
gitignore = Path('.gitignore')
ignore = gitignore.read_text() if gitignore.exists() else ''
entry = 'packages/rpcs3_internal_bridge/ios/Frameworks/\n'
if entry not in ignore:
    if ignore and not ignore.endswith('\n'):
        ignore += '\n'
    gitignore.write_text(ignore + entry)

print('RPCS3 internal UI/library wiring applied without touching Dolphin.')
