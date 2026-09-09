#!/usr/bin/env python3
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


# Reuse the already-bundled helper extension for a universal JIT attach to
# NeoStation itself. Dolphin's existing legacy route remains explicit.
dolphin_path = Path(
    'packages/dolphin_internal_bridge/ios/Classes/DolphinInternalBridgePlugin.mm'
)
dolphin = dolphin_path.read_text()
dolphin = replace_once(
    dolphin,
    '''static BOOL DOLLaunchHelper(DOLHelperSession* session,
                            NSData* pairingData,
                            NSString* logPath,
                            NSError** error) {''',
    '''static BOOL DOLLaunchHelper(DOLHelperSession* session,
                            NSData* pairingData,
                            NSString* scriptMode,
                            NSString* logPath,
                            NSError** error) {''',
    'DOLLaunchHelper signature',
)
dolphin = replace_once(
    dolphin,
    '''    @"pairingData" : [pairingData base64EncodedStringWithOptions:0],
  };''',
    '''    @"pairingData" : [pairingData base64EncodedStringWithOptions:0],
    @"scriptMode" : scriptMode ?: @"legacy",
  };''',
    'DOLLaunchHelper request mode',
)
dolphin = replace_once(
    dolphin,
    'DOLLaunchHelper(helper, pairingData, logPath, &helperError)',
    'DOLLaunchHelper(helper, pairingData, @"legacy", logPath, &helperError)',
    'Dolphin legacy helper call',
)
dolphin = replace_once(
    dolphin,
    'BOOL ready = _attached && !_finished;',
    'BOOL ready = _attached;',
    'helper fresh attach latch',
)
host_jit = r'''  if ([call.method isEqualToString:@"prepareHostJit"]) {
    NSDictionary* args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
    NSString* pairingPath = [args[@"pairingFilePath"] isKindOfClass:NSString.class]
                                ? args[@"pairingFilePath"] : @"";
    NSString* mode = [[args[@"mode"] isKindOfClass:NSString.class]
                         ? args[@"mode"] : @"universal" lowercaseString];
    dispatch_async(_runtimeQueue, ^{
      NSMutableDictionary* state = [@{
        @"success" : @NO,
        @"stikjitConnected" : @NO,
        @"pidAttached" : @NO,
        @"logs" : @[],
      } mutableCopy];
      void (^finish)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{ result(state); });
      };
      if (![mode isEqualToString:@"universal"]) {
        state[@"message"] = @"Only universal host JIT is exposed to non-Dolphin engines.";
        finish(); return;
      }
      if (@available(iOS 17.4, *)) {} else {
        state[@"message"] = @"Built-in StikJIT requires iOS 17.4 or newer.";
        finish(); return;
      }
      if (!DOLHostHasGetTaskAllow()) {
        state[@"message"] = @"This NeoStation installation does not preserve get-task-allow.";
        finish(); return;
      }
      @synchronized(self) {
        if (self.launchInProgress || self.stopInProgress || self.helperSession != nil ||
            neostation_dolphin_is_running() != 0) {
          state[@"message"] = @"NeoStation JIT helper is already in use.";
          finish(); return;
        }
      }
      NSData* pairingData = [[NSData alloc] initWithContentsOfFile:pairingPath
                                                          options:NSDataReadingMappedIfSafe
                                                            error:nil];
      if (pairingData.length == 0) {
        state[@"message"] = @"Import a readable pairing file before enabling RPCS3 JIT.";
        finish(); return;
      }
      NSError* helperError = nil;
      DOLHelperSession* helper = [[DOLHelperSession alloc] initWithLogPath:@"" error:&helperError];
      if (!helper) {
        state[@"message"] = helperError.localizedDescription ?: @"Could not prepare the NeoStation JIT helper.";
        finish(); return;
      }
      self.helperSession = helper;
      [helper startReader];
      if (!DOLLaunchHelper(helper, pairingData, @"universal", @"", &helperError)) {
        state[@"message"] = helperError.localizedDescription ?: @"Could not launch the NeoStation JIT helper.";
        [helper close]; self.helperSession = nil; finish(); return;
      }
      if (![helper waitUntilConnected:kHelperLaunchTimeout]) {
        state[@"message"] = helper.finalMessage.length ? helper.finalMessage : @"NeoStation JIT helper did not connect.";
        state[@"logs"] = helper.logs;
        [helper close]; self.helperSession = nil; finish(); return;
      }
      state[@"stikjitConnected"] = @YES;
      if (!DOLWaitForFreshDebuggerAttach(helper, kDebuggerAttachTimeout)) {
        state[@"message"] = helper.finalMessage.length ? helper.finalMessage : @"StikJIT did not attach to the NeoStation PID.";
        state[@"logs"] = helper.logs;
        [helper close]; self.helperSession = nil; finish(); return;
      }
      state[@"pidAttached"] = @YES;
      if (![helper waitUntilFinished:kLegacyCompletionTimeout] || !helper.success || !DOLHostIsDebugged()) {
        state[@"message"] = helper.finalMessage.length ? helper.finalMessage : @"Universal StikJIT transaction did not complete.";
        state[@"logs"] = helper.logs;
        [helper close]; self.helperSession = nil; finish(); return;
      }
      state[@"logs"] = helper.logs;
      state[@"success"] = @YES;
      state[@"message"] = @"Universal JIT is enabled for the NeoStation process.";
      [helper close]; self.helperSession = nil;
      finish();
    });
    return;
  }
'''
dolphin = replace_once(
    dolphin,
    '- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {\n',
    '- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {\n'
    + host_jit,
    'prepareHostJit method',
)
dolphin_path.write_text(dolphin)

# RPCS3 library is now private NeoStation storage, not a bookmark into another
# app's Files container.
library_path = Path('lib/services/rpcs3_library_service.dart')
library = library_path.read_text()
library = library.replace(
    "import 'package:external_folder_access/external_folder_access.dart';\n", ''
)
library = replace_region(
    library,
    '  static Future<void> initialize() async {',
    '  /// Restores cached virtual PS3 rows',
    '''  static Future<void> initialize() async {
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
    '''  /// Compatibility entry point. RPCS3 Data is now owned by NeoStation.
  static Future<Rpcs3SyncResult?> linkAndSync() async {
    if (!Platform.isIOS) return null;
    return syncInternalLibrary();
  }

  static Future<Rpcs3SyncResult> syncInternalLibrary() async {
    await initialize();
    return syncLinkedLibrary();
  }

''',
    'RPCS3 linkAndSync retirement',
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

# Remove RPCS3 from Settings > Directories. Its imports live in the PS3 screen.
settings_path = Path(
    'lib/screens/settings_screen/new_settings_options/directories_settings_content.dart'
)
settings = settings_path.read_text()
settings = settings.replace(
    "import 'package:neostation/services/rpcs3_library_service.dart';\n", ''
)
settings = settings.replace(
    "import 'package:neostation/l10n/rpcs3_library_locale.dart';\n", ''
)
settings = replace_region(
    settings,
    '  Future<void> _linkRpcs3DataFolder() async {',
    '  List<Widget> _iosEmulatorCards(ThemeData theme) {',
    '  List<Widget> _iosEmulatorCards(ThemeData theme) {',
    'RPCS3 directory actions',
)
settings = settings.replace('      _buildIOSRpcs3Section(theme),\n', '')
settings = replace_region(
    settings,
    '  Widget _buildIOSRpcs3Section(ThemeData theme) {',
    '  Widget _buildIOSArmsx2Section(ThemeData theme) {',
    '  Widget _buildIOSArmsx2Section(ThemeData theme) {',
    'RPCS3 directory card',
)
settings_path.write_text(settings)

# Add a top-right PS3 import affordance matching the Dolphin library action.
games_path = Path('lib/screens/game_screen/my_games_list.dart')
games = games_path.read_text()
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
games = replace_once(
    games,
    '            // DOLPHIN_ISOLATION_END: playlist_actions\n',
    '            // DOLPHIN_ISOLATION_END: playlist_actions\n' + rpcs3_actions,
    'RPCS3 playlist action block',
)
games_path.write_text(games)

# Mark sessions and failures as internal RPCS3, not StikDebug.
launch_path = Path('lib/services/game/game_launch_service.dart')
launch = launch_path.read_text().replace(
    "'ios_rpcs3_stikdebug'", "'ios_rpcs3_internal'"
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
launch = replace_once(
    launch,
    old_failure,
    new_failure,
    'RPCS3 internal error surface',
)
launch_path.write_text(launch)

# Never commit the extracted release core itself.
gitignore = Path('.gitignore')
ignore = gitignore.read_text() if gitignore.exists() else ''
entry = 'packages/rpcs3_internal_bridge/ios/Frameworks/\n'
if entry not in ignore:
    if ignore and not ignore.endswith('\n'):
        ignore += '\n'
    gitignore.write_text(ignore + entry)
