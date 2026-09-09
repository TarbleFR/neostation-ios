#!/usr/bin/env python3
"""Wire the embedded RPCS3 engine into NeoStation's existing PS3 UI/library.

This patch is deliberately surgical: it does not read or modify any Dolphin
source file, and it preserves the mature RPCS3 metadata/catalog helpers.
"""
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one match, found {count}')
    return text.replace(old, new, 1)


def remove_function(text: str, signature: str, label: str) -> str:
    """Remove exactly one Dart method using balanced braces, not line ranges."""
    start = text.find(signature)
    if start < 0:
        return text
    brace = text.find('{', start + len(signature))
    if brace < 0:
        raise SystemExit(f'{label}: opening brace missing')
    depth = 0
    quote = None
    escaped = False
    i = brace
    while i < len(text):
        ch = text[i]
        if quote is not None:
            if escaped:
                escaped = False
            elif ch == '\\':
                escaped = True
            elif ch == quote:
                quote = None
        else:
            if ch in ("'", '"'):
                quote = ch
            elif ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    end = i + 1
                    while end < len(text) and text[end] in ' \t':
                        end += 1
                    if end < len(text) and text[end] == '\r':
                        end += 1
                    if end < len(text) and text[end] == '\n':
                        end += 1
                    if end < len(text) and text[end] == '\n':
                        end += 1
                    return text[:start] + text[end:]
        i += 1
    raise SystemExit(f'{label}: closing brace missing')


# ---------------------------------------------------------------------------
# RPCS3 library: keep all discovery/catalog/cache code, but make NeoStation's
# private Application Support directory the authoritative Data root.
# ---------------------------------------------------------------------------
library_path = Path('lib/services/rpcs3_library_service.dart')
library = library_path.read_text()

library = library.replace(
    "/// Imports the game list exposed by the unofficial RPCS3 iOS port.\n///\n/// RPCS3 exposes its persistent directory through Files at:\n/// `On My iPhone/iPad > RPCS3 > Data`.\n///\n/// The iOS build does not currently expose a library-export URL scheme, so\n/// NeoStation bookmarks that Data directory and mirrors RPCS3's own discovery\n/// rules. Metadata comes from `PARAM.SFO` under:\n",
    "/// Imports the game list owned by NeoStation's embedded RPCS3 Core.\n///\n/// The authoritative PS3 data root is private NeoStation Application Support at\n/// `NeoStation/RPCS3/Data`. Existing PARAM.SFO discovery and metadata fallback\n/// rules are preserved. Metadata comes from `PARAM.SFO` under:\n",
)
library = library.replace(
    "/// Imported rows intentionally use an internal `rpcs3-library://` URI. They are\n/// display-only until RPCS3 publishes a supported direct-game deeplink.\n",
    "/// Imported rows keep the internal `rpcs3-library://` URI. Launching resolves\n/// the title ID and boots it directly through the embedded RPCS3 Core.\n",
)

old_initialize = '''  /// Restores the security-scoped bookmark and the last lightweight cache.
  static Future<void> initialize() async {
    await loadCachedLibrary();
    if (!Platform.isIOS) return;

    try {
      final selected = await ExternalFolderAccess.resolveBookmarkedFolder(
        key: bookmarkKey,
      );
      if (selected != null) {
        _linkedDataPath = await _normalizeDataRoot(selected);
      }
    } catch (e) {
      _log.w('Rpcs3LibraryService: could not restore linked Data folder: $e');
    }
  }
'''
new_initialize = '''  /// Restores the lightweight cache and prepares NeoStation's private RPCS3
  /// data root. No separately installed RPCS3 application is required.
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
if old_initialize in library:
    library = replace_once(
        library,
        old_initialize,
        new_initialize,
        'RPCS3 internal initialize',
    )
elif "NeoStation's private RPCS3" not in library:
    raise SystemExit('RPCS3 initialize block is not in a recognized state')

sync_anchor = '''  /// Reads the currently linked RPCS3 Data directory and imports its PS3 rows.
  static Future<Rpcs3SyncResult> syncLinkedLibrary() async {
'''
if 'static Future<Rpcs3SyncResult> syncInternalLibrary() async {' not in library:
    internal_sync = '''  /// Synchronizes the PS3 library owned by the embedded RPCS3 Core.
  static Future<Rpcs3SyncResult> syncInternalLibrary() async {
    await initialize();
    return syncLinkedLibrary();
  }

'''
    library = replace_once(
        library,
        sync_anchor,
        internal_sync + sync_anchor,
        'RPCS3 internal sync entry point',
    )

old_resolver = '''  static Future<String?> _resolveLinkedDataRoot() async {
    final current = linkedDataPath;
    if (current != null) return current;
    if (!Platform.isIOS) return null;

    try {
      final selected = await ExternalFolderAccess.resolveBookmarkedFolder(
        key: bookmarkKey,
      );
      if (selected == null) return null;
      final normalized = await _normalizeDataRoot(selected);
      _linkedDataPath = normalized;
      return normalized;
    } catch (error) {
      _log.w('Rpcs3LibraryService: linked Data folder resolve failed: $error');
      return null;
    }
  }
'''
new_resolver = '''  static Future<String?> _resolveLinkedDataRoot() async {
    final current = linkedDataPath;
    if (current != null) return current;
    if (!Platform.isIOS) return null;
    await initialize();
    return linkedDataPath;
  }
'''
if old_resolver in library:
    library = replace_once(
        library,
        old_resolver,
        new_resolver,
        'RPCS3 private data-root resolver',
    )
elif "await initialize();\n    return linkedDataPath;" not in library:
    raise SystemExit('RPCS3 data-root resolver is not in a recognized state')

library = library.replace(
    "throw StateError('RPCS3 Data folder is not linked.');",
    "throw StateError('RPCS3 internal Data directory is unavailable.');",
)
library_path.write_text(library)


# ---------------------------------------------------------------------------
# PS3 library UI: expose the dedicated import popup directly in the game view.
# ---------------------------------------------------------------------------
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


# ---------------------------------------------------------------------------
# Settings: remove the obsolete external RPCS3 Data-folder controls using
# brace-balanced method removal. This does not touch the surrounding emulator
# cards and therefore cannot truncate ARMSX2/MeloNX settings.
# ---------------------------------------------------------------------------
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
settings = settings.replace('      _buildIOSRpcs3Section(theme),\n', '')
settings = remove_function(
    settings,
    '  Future<void> _linkRpcs3DataFolder() async ',
    'RPCS3 external link action',
)
settings = remove_function(
    settings,
    '  Future<void> _syncWithRpcs3() async ',
    'RPCS3 external sync action',
)
settings = remove_function(
    settings,
    '  Widget _buildIOSRpcs3Section(ThemeData theme) ',
    'RPCS3 external directory card',
)
settings_path.write_text(settings)


# ---------------------------------------------------------------------------
# Launch surface: identify the session as internal and propagate precise
# firmware/JIT/Core failures from Rpcs3LaunchService.
# ---------------------------------------------------------------------------
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

print('RPCS3 internal UI/library wiring applied; metadata helpers preserved; Dolphin untouched.')
