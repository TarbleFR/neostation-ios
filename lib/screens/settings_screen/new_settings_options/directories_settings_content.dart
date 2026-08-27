import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:file_picker/file_picker.dart';
import 'package:external_folder_access/external_folder_access.dart';
import 'package:neostation/services/retroarch_library_service.dart';
import 'package:neostation/services/armsx2_library_service.dart';
import 'package:neostation/services/melonx_library_service.dart';
import 'package:neostation/services/rpcs3_library_service.dart';
import 'package:neostation/services/ios_shortcut_jit_launch_service.dart';
import 'package:neostation/services/ios_emulator_preference_service.dart';
import 'package:neostation/services/manic_emu_launch_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/l10n/rpcs3_library_locale.dart';
import 'package:neostation/l10n/manic_emu_locale.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/esde_import_service.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/move_user_data_dialog.dart';
import 'package:neostation/widgets/permission_check_wrapper.dart';
import 'package:neostation/widgets/restart_required_dialog.dart';
import 'package:neostation/widgets/tv_directory_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:neostation/utils/adaptive_scroll.dart';

import 'settings_title.dart';
import 'widgets/settings_section_header.dart';
import 'widgets/settings_action_button.dart';

class DirectoriesSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;

  const DirectoriesSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
  });

  @override
  State<DirectoriesSettingsContent> createState() =>
      DirectoriesSettingsContentState();
}

class DirectoriesSettingsContentState
    extends State<DirectoriesSettingsContent> {
  final ScrollController _scrollController = ScrollController();
  final AdaptiveScroller _scroller = AdaptiveScroller();

  /// GlobalKeys for the navigable rows, used to keep the focused row visible
  /// during gamepad navigation.
  final List<GlobalKey> _itemKeys = [];
  int _lastScrollIndex = 0;

  /// Grows [_itemKeys] to cover the current navigable-item count.
  void _ensureKeys(int count) {
    while (_itemKeys.length < count) {
      _itemKeys.add(GlobalKey());
    }
  }

  List<String> _currentRomFolders = [];
  String? _currentUserDataPath;
  bool _isLoading = true;

  // iOS-only: live-linking RetroArch's external folder via a persisted
  // security-scoped bookmark. ARMSX2 and MeloNX are sync-only and never
  // expose a folder picker in this screen.
  String? _linkingFolderKey;

  // Migration progress state (shown inline, no dialog).
  bool _isMigrating = false;
  double _migrationProgress = 0.0;
  String _migrationFile = '';

  /// Whether the ES-DE import feature exists at all on this platform.
  /// False on iOS: an ES-DE install lives in another app's sandbox, which
  /// iOS doesn't expose the way desktop and Android do, so the whole
  /// feature — list entries, section header, progress bar, result summary
  /// and actions — is absent rather than present-but-disabled. Every ES-DE
  /// entry point below is gated on this one flag.
  static final bool _esdeSupported = !Platform.isIOS;

  // ES-DE import progress state (shown inline, no dialog).
  bool _isImporting = false;
  double _importProgress = 0.0;
  String _importLabel = '';
  EsdeImportResult? _lastEsdeResult;

  static final _log = LoggerService.instance;

  // Flat list of navigable items used for gamepad index tracking.
  // Layout: user_data | rescan | add_rom | remove_rom:N...
  final List<Map<String, dynamic>> _directoryItems = [];

  @override
  void initState() {
    super.initState();
    _loadCurrentPaths();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void scrollToIndex(int index) {
    if (index < 0 || index >= _directoryItems.length) return;
    _ensureKeys(_directoryItems.length);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final itemContext = _itemKeys[index].currentContext;
      if (itemContext != null) {
        _lastScrollIndex = index;
        _scroller.ensureVisible(itemContext);
        return;
      }

      // ListView.builder lazily omits off-screen ROM-folder rows. Move one
      // viewport in the requested direction so the target gets built, then
      // finish with ensureVisible using its real rendered height.
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      final direction = index >= _lastScrollIndex ? 1.0 : -1.0;
      _lastScrollIndex = index;
      final target =
          (position.pixels + direction * position.viewportDimension * 0.72)
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble();

      _scrollController
          .animateTo(
            target,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
          )
          .then((_) {
            if (!mounted || index >= _itemKeys.length) return;
            final builtContext = _itemKeys[index].currentContext;
            if (builtContext != null) {
              _scroller.ensureVisible(builtContext);
            }
          });
    });
  }

  void _buildDirectoryItems() {
    _directoryItems.clear();

    // 0: User Data Location
    _directoryItems.add({
      'title': AppLocale.userDataLocation,
      'subtitle': AppLocale.userDataLocationSubtitle,
      'action': 'user_data',
    });

    // 1: Rescan All ROM Folders
    _directoryItems.add({
      'title': AppLocale.rescanAllFolders,
      'subtitle': AppLocale.rescanAllFoldersSubtitle,
      'action': 'rescan',
    });

    // 2: Add ROM Folder
    _directoryItems.add({
      'title': AppLocale.addRomFolder,
      'subtitle': AppLocale.romsFolderSubtitle,
      'action': 'add_rom',
    });

    // 3..n+2: Individual ROM folders (removable)
    for (final path in _currentRomFolders) {
      _directoryItems.add({
        'title': path,
        'subtitle': AppLocale.pressToRemoveFolder,
        'action': 'remove_rom',
        'path': path,
      });
    }

    // ES-DE import actions (grouped under their own section header in build).
    // Absent where the feature isn't supported (see [_esdeSupported]).
    // Leaving _esdeSectionStart at -1 keeps its header out of the list too,
    // since build() inserts that header by index match.
    if (!_esdeSupported) {
      _esdeSectionStart = -1;
      return;
    }

    _esdeSectionStart = _directoryItems.length;
    _directoryItems.add({
      'title': AppLocale.esdeSelectFolder,
      'subtitle': AppLocale.esdeSelectFolderSubtitle,
      'action': 'esde_select_folder',
    });
    _directoryItems.add({
      'title': AppLocale.esdeRunImport,
      'subtitle': AppLocale.esdeRunImportSubtitle,
      'action': 'esde_run_import',
    });
    _directoryItems.add({
      'title': AppLocale.esdeReset,
      'subtitle': AppLocale.esdeResetSubtitle,
      'action': 'esde_reset',
    });
  }

  // Index of the first ES-DE item in [_directoryItems]; used to insert the
  // "ES-DE Import" section header at the right position.
  int _esdeSectionStart = -1;

  // ES-DE import requires at least one ROM directory to match games against,
  // so the whole section is disabled until one is configured.
  bool get _esdeEnabled => _currentRomFolders.isNotEmpty;

  static const Set<String> _esdeActions = {
    'esde_select_folder',
    'esde_run_import',
    'esde_reset',
  };

  /// Whether an ES-DE action is currently disabled. Requires a ROM directory
  /// for the whole section, plus a selected ES-DE folder for the import action.
  bool _isEsdeDisabled(String action) {
    if (!_esdeActions.contains(action)) return false;
    if (!_esdeEnabled) return true;
    if (action == 'esde_run_import' && _esdePath.trim().isEmpty) return true;
    return false;
  }

  Future<void> _loadCurrentPaths() async {
    try {
      final foldersFuture = ConfigRepository.getUserRomFolders();
      final userDataFuture = ConfigService.getUserDataPath();
      _currentRomFolders = await foldersFuture;
      _currentUserDataPath = await userDataFuture;
    } catch (e) {
      _log.e('Failed to load directory configuration: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _buildDirectoryItems();
        });
      }
    }
  }

  Future<void> _handleItemTap(Map<String, dynamic> item) async {
    final action = item['action'] as String;
    // Disabled ES-DE actions are inert — no toast, no sound, no work.
    if (_isEsdeDisabled(action)) return;
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    switch (item['action']) {
      case 'user_data':
        await _selectUserDataLocation();
        break;
      case 'rescan':
        await configProvider.scanSystems();
        break;
      case 'add_rom':
        await _selectRomFolder();
        break;
      case 'remove_rom':
        await _removeRomFolder(item['path'] as String);
        break;
      case 'esde_select_folder':
        await _selectEsdeFolder();
        break;
      case 'esde_run_import':
        await _runEsdeImport();
        break;
      case 'esde_reset':
        await _resetEsdeImport();
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // ES-DE import
  // ---------------------------------------------------------------------------

  String get _esdePath =>
      context.read<SqliteConfigProvider>().config.esdeFolderPath;

  Future<void> _selectEsdeFolder() async {
    if (!_esdeSupported) return;
    try {
      String? selected;

      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (!mounted) return;
        if (isTV) {
          selected = await TvDirectoryPicker.show(context);
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            if (uri != null) {
              final uriStr = uri.toString();
              final hasFiles = await PermissionService.hasAllFilesAccess();
              selected =
                  await UserDataLocationService.resolveAndroidUserDataPath(
                    uriStr,
                    hasAllFilesAccess: hasFiles,
                  ) ??
                  UserDataLocationService.safUriToRealPath(uriStr);
            }
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' && mounted) {
              selected = await TvDirectoryPicker.show(context);
            }
          }
        }
      } else {
        selected = await FilePicker.getDirectoryPath(
          dialogTitle: AppLocale.esdeSelectFolder.getString(context),
        );
      }

      if (selected == null || !mounted) return;
      if (selected.endsWith(Platform.pathSeparator)) {
        selected = selected.substring(0, selected.length - 1);
      }

      await context.read<SqliteConfigProvider>().updateEsdeFolderPath(selected);
      // Refresh the fallback map so any already-recorded systems resolve.
      if (mounted) await context.read<FileProvider>().refreshEsde();
      if (mounted) setState(() {});
    } catch (e) {
      _log.e('ES-DE folder selection failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          '$e',
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _runEsdeImport() async {
    if (!_esdeSupported) return;
    final root = _esdePath;
    if (root.trim().isEmpty) {
      AppNotification.showNotification(
        context,
        AppLocale.esdeImportNoFolder.getString(context),
        type: NotificationType.info,
      );
      return;
    }
    if (_isImporting) return;

    const notificationId = 'esde_import_progress';

    // Resolve ES-DE strings before the async import so the progress callback
    // (which may run after this screen was left) can use them safely.
    final localeEsdeImporting = AppLocale.esdeImporting.getString(context);
    final localeEsdeImportNotEsdeFolder = AppLocale.esdeImportNotEsdeFolder
        .getString(context);
    final localeEsdeImportNothingFound = AppLocale.esdeImportNothingFound
        .getString(context);
    final localeEsdeImportComplete = AppLocale.esdeImportComplete.getString(
      context,
    );
    final localeEsdeSummaryGames = AppLocale.esdeSummaryGames.getString(
      context,
    );
    final localeEsdeSummarySystems = AppLocale.esdeSummarySystems.getString(
      context,
    );

    setState(() {
      _isImporting = true;
      _importProgress = 0.0;
      _importLabel = '';
      _lastEsdeResult = null;
    });

    GlobalNotificationService().show(
      id: notificationId,
      message: localeEsdeImporting,
      type: GlobalNotificationType.info,
      progress: 0,
    );

    EsdeImportResult? result;
    String? error;
    try {
      result = await EsdeImportService.import(
        root,
        onProgress: (p, label) {
          if (mounted) {
            setState(() {
              _importProgress = p;
              _importLabel = label;
            });
          }
          GlobalNotificationService().update(
            id: notificationId,
            message: label.isEmpty
                ? localeEsdeImporting
                : '$localeEsdeImporting: $label',
            type: GlobalNotificationType.info,
            progress: p,
          );
        },
      );
      // Rebuild the fallback map now that esde_media_dir rows exist.
      if (mounted) await context.read<FileProvider>().refreshEsde();
    } catch (e) {
      error = e.toString();
      _log.e('ES-DE import failed: $e');
    }

    // Report the outcome through the global notification so the header
    // dropdown reflects it even if this screen was left mid-import.
    if (error != null) {
      GlobalNotificationService().update(
        id: notificationId,
        message: error,
        type: GlobalNotificationType.error,
        progress: null,
      );
    } else if (result != null) {
      if (!result.gamelistsDirFound) {
        GlobalNotificationService().update(
          id: notificationId,
          message: localeEsdeImportNotEsdeFolder,
          type: GlobalNotificationType.error,
          progress: null,
        );
      } else if (result.gamesImported == 0 && result.systemsMatched == 0) {
        GlobalNotificationService().update(
          id: notificationId,
          message: localeEsdeImportNothingFound,
          type: GlobalNotificationType.info,
          progress: null,
        );
      } else {
        GlobalNotificationService().update(
          id: notificationId,
          message:
              '$localeEsdeImportComplete: '
              '${result.gamesImported} $localeEsdeSummaryGames, '
              '${result.systemsMatched} $localeEsdeSummarySystems',
          type: GlobalNotificationType.success,
          progress: null,
        );
      }
    }

    if (!mounted) return;
    final showSummary =
        error == null &&
        result != null &&
        result.gamelistsDirFound &&
        (result.gamesImported > 0 || result.systemsMatched > 0);
    setState(() {
      _isImporting = false;
      _lastEsdeResult = showSummary ? result : null;
    });
  }

  Future<void> _resetEsdeImport() async {
    if (!_esdeSupported || _isImporting) return;

    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.esdeReset.getString(context),
      body: AppLocale.esdeResetConfirmBody.getString(context),
      confirmLabel: AppLocale.esdeReset.getString(context),
      icon: Symbols.restart_alt_rounded,
    );
    if (!confirmed || !mounted) return;

    try {
      final cleared = await EsdeImportService.reset();
      if (mounted) {
        await context.read<SqliteConfigProvider>().updateEsdeFolderPath('');
      }
      if (mounted) await context.read<FileProvider>().refreshEsde();
      if (!mounted) return;
      setState(() => _lastEsdeResult = null);
      AppNotification.showNotification(
        context,
        '${AppLocale.esdeResetComplete.getString(context)} ($cleared)',
        type: NotificationType.info,
      );
    } catch (e) {
      _log.e('ES-DE reset failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          '$e',
          type: NotificationType.error,
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // ROM folder picker
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // iOS: link + sync with RetroArch
  // ---------------------------------------------------------------------------

  /// Live-links RetroArch's external folder via a persisted security-scoped
  /// bookmark instead of copying its contents in.
  Future<void> _linkExternalFolder({
    required String bookmarkKey,
    required String successMessage,
  }) async {
    if (_linkingFolderKey != null) return;

    setState(() => _linkingFolderKey = bookmarkKey);
    try {
      final previousPath = bookmarkKey == ManicEmuLaunchService.bookmarkKey
          ? ConfigService.linkedManicEmuFolderPath
          : ConfigService.linkedExternalFolderPath;
      final selected = await ExternalFolderAccess.pickAndBookmarkFolder(
        key: bookmarkKey,
      );
      if (selected == null || !mounted) return;
      final resolved = await ExternalFolderAccess.resolveBookmarkedFolder(
        key: bookmarkKey,
      );
      final activePath = resolved ?? selected;
      if (!mounted) return;

      if (bookmarkKey == ManicEmuLaunchService.bookmarkKey) {
        ConfigService.linkedManicEmuFolderPath = activePath;
      } else {
        ConfigService.linkedExternalFolderPath = activePath;
      }

      final configProvider = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      );
      // RetroArch App Store/TestFlight and Manic EMU App Store/IPA are
      // equivalent linked-library providers within their own family. Only
      // update NeoStation's active source reference; never modify an app
      // container. Force a scan even when iOS resolves both picks to the same
      // display path.
      final previousIsUsedByOtherLibrary =
          previousPath != null &&
          ((bookmarkKey == ManicEmuLaunchService.bookmarkKey &&
                  previousPath == ConfigService.linkedExternalFolderPath) ||
              (bookmarkKey != ManicEmuLaunchService.bookmarkKey &&
                  previousPath == ConfigService.linkedManicEmuFolderPath));
      await configProvider.replaceRomFolder(
        previousIsUsedByOtherLibrary ? null : previousPath,
        activePath,
        scan: true,
        // RetroArch's exported index and existing rows remain usable until a
        // new App Store/TestFlight callback succeeds. Manic EMU scans directly
        // from its linked source and can safely discard the former association.
        purgePreviousEntries:
            bookmarkKey == ManicEmuLaunchService.bookmarkKey,
      );
      if (!mounted) return;

      await _loadCurrentPaths();
      if (!mounted) return;

      AppNotification.showNotification(
        context,
        successMessage,
        type: NotificationType.info,
      );
    } catch (e) {
      _log.e('Link external folder failed ($bookmarkKey): $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.iosEmuLinkingFailed
              .getString(context)
              .replaceFirst('{error}', e.toString()),
          type: NotificationType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _linkingFolderKey = null);
    }
  }

  Future<void> _linkNeoSyncSaveFolder({
    required String bookmarkKey,
    required String emulatorName,
  }) async {
    if (_linkingFolderKey != null) return;
    setState(() => _linkingFolderKey = bookmarkKey);
    try {
      final selected = await ExternalFolderAccess.pickAndBookmarkFolder(
        key: bookmarkKey,
      );
      if (selected == null || !mounted) return;
      final resolved = await ExternalFolderAccess.resolveBookmarkedFolder(
        key: bookmarkKey,
      );
      final activePath = resolved ?? selected;
      if (bookmarkKey == ConfigService.armsx2NeoSyncBookmarkKey) {
        ConfigService.linkedArmsx2SaveFolderPath = activePath;
      } else if (bookmarkKey == ConfigService.melonxNeoSyncBookmarkKey) {
        ConfigService.linkedMelonxSaveFolderPath = activePath;
      }
      if (mounted) setState(() {});
      _log.i('NeoSync $emulatorName save folder linked: $activePath');
    } catch (e) {
      _log.e('NeoSync $emulatorName save-folder link failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.iosEmuLinkingFailed
              .getString(context)
              .replaceFirst('{error}', e.toString()),
          type: NotificationType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _linkingFolderKey = null);
    }
  }

  Future<void> _syncWithRetroArch() async {
    final opened = await RetroArchLibraryService.requestLibrarySync();
    if (!mounted) return;
    AppNotification.showNotification(
      context,
      opened
          ? AppLocale.iosRetroarchSyncRequested.getString(context)
          : AppLocale.iosRetroarchUnavailable.getString(context),
      type: opened ? NotificationType.info : NotificationType.error,
    );
  }

  Future<void> _syncWithArmsx2() async {
    final opened = await Armsx2LibraryService.requestLibrarySync();
    if (!mounted) return;
    AppNotification.showNotification(
      context,
      opened
          ? AppLocale.iosArmsx2SyncRequested.getString(context)
          : AppLocale.iosArmsx2Unavailable.getString(context),
      type: opened ? NotificationType.info : NotificationType.error,
    );
  }

  Future<void> _configureArmsx2Launch() async {
    final opened =
        await IosShortcutJitLaunchService.openArmsx2ShortcutInstaller();
    if (!mounted || opened) return;

    AppNotification.showNotification(
      context,
      AppLocale.shortcutSetupOpenError.getString(context),
      type: NotificationType.error,
    );
  }

  Future<void> _syncWithMeloNX() async {
    final opened = await MelonxLibraryService.requestLibrarySync();
    if (!mounted) return;
    AppNotification.showNotification(
      context,
      opened
          ? AppLocale.iosMelonxSyncRequested.getString(context)
          : AppLocale.iosMelonxUnavailable.getString(context),
      type: opened ? NotificationType.info : NotificationType.error,
    );
  }

  Future<void> _configureMeloNXLaunch() async {
    final opened =
        await IosShortcutJitLaunchService.openMeloNXShortcutInstaller();
    if (!mounted || opened) return;

    AppNotification.showNotification(
      context,
      AppLocale.shortcutSetupOpenError.getString(context),
      type: NotificationType.error,
    );
  }

  Future<void> _linkRpcs3DataFolder() async {
    if (_linkingFolderKey != null) return;

    setState(() => _linkingFolderKey = Rpcs3LibraryService.bookmarkKey);
    try {
      final result = await Rpcs3LibraryService.linkAndSync();
      if (result == null || !mounted) return;

      setState(() {});
      AppNotification.showNotification(
        context,
        result.discoveredGames == 0
            ? Rpcs3LibraryLocale.noGames(context)
            : Rpcs3LibraryLocale.syncComplete(context, result.discoveredGames),
        type: result.discoveredGames == 0
            ? NotificationType.info
            : NotificationType.success,
      );
    } on FormatException {
      if (mounted) {
        AppNotification.showNotification(
          context,
          Rpcs3LibraryLocale.invalidFolder(context),
          type: NotificationType.error,
        );
      }
    } catch (e) {
      _log.e('RPCS3 folder link/sync failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          Rpcs3LibraryLocale.syncFailed(context, e),
          type: NotificationType.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _linkingFolderKey = null);
      }
    }
  }

  Future<void> _syncWithRpcs3() async {
    try {
      final result = await Rpcs3LibraryService.syncLinkedLibrary();
      if (!mounted) return;
      setState(() {});
      AppNotification.showNotification(
        context,
        result.discoveredGames == 0
            ? Rpcs3LibraryLocale.noGames(context)
            : Rpcs3LibraryLocale.syncComplete(context, result.discoveredGames),
        type: result.discoveredGames == 0
            ? NotificationType.info
            : NotificationType.success,
      );
    } catch (e) {
      _log.e('RPCS3 library sync failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          Rpcs3LibraryLocale.syncFailed(context, e),
          type: NotificationType.error,
        );
      }
    }
  }

  List<Widget> _iosEmulatorCards(ThemeData theme) {
    if (!Platform.isIOS) return const [];

    return [
      _buildIOSPrimaryEmulatorSection(theme),
      _buildIOSRetroArchSection(theme),
      _buildIOSManicEmuSection(theme),
      _buildIOSRpcs3Section(theme),
      _buildIOSArmsx2Section(theme),
      _buildIOSMeloNXSection(theme),
    ];
  }

  Widget _buildIOSPrimaryEmulatorSection(ThemeData theme) {
    return FutureBuilder<IosLibraryEmulator>(
      future: IosEmulatorPreferenceService.primary(),
      builder: (context, snapshot) {
        final selected = snapshot.data ?? IosLibraryEmulator.retroArch;
        return Card(
          margin: EdgeInsets.only(bottom: 12.r),
          child: ListTile(
            leading: const Icon(Symbols.swap_horiz_rounded),
            title: Text(ManicEmuLocale.text(context, 'primaryTitle')),
            subtitle: Text(
              selected == IosLibraryEmulator.manicEmu
                  ? 'Manic EMU'
                  : 'RetroArch',
            ),
            trailing: DropdownButton<IosLibraryEmulator>(
              value: selected,
              items: const [
                DropdownMenuItem(
                  value: IosLibraryEmulator.retroArch,
                  child: Text('RetroArch'),
                ),
                DropdownMenuItem(
                  value: IosLibraryEmulator.manicEmu,
                  child: Text('Manic EMU'),
                ),
              ],
              onChanged: (value) async {
                if (value == null) return;
                await IosEmulatorPreferenceService.setPrimary(value);
                if (mounted) setState(() {});
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildIOSManicEmuSection(ThemeData theme) {
    final isLinked = ConfigService.linkedManicEmuFolderPath != null;
    return _buildIOSEmulatorCard(
      theme: theme,
      name: 'Manic EMU',
      icon: Symbols.sports_esports_rounded,
      statusText: isLinked
          ? ManicEmuLocale.text(context, 'libraryLinked')
          : ManicEmuLocale.text(context, 'libraryNeedsLink'),
      isLinked: isLinked,
      bookmarkKey: ManicEmuLaunchService.bookmarkKey,
      successMessage: ManicEmuLocale.text(context, 'libraryLinkSuccess'),
    );
  }

  Widget _buildIOSRetroArchSection(ThemeData theme) {
    final isLinked = ConfigService.linkedExternalFolderPath != null;
    final hasSynced = RetroArchLibraryService.hasSyncedLibrary;

    final String statusText;
    if (!isLinked) {
      statusText = AppLocale.iosRetroarchStatusNeedsLink.getString(context);
    } else if (!hasSynced) {
      statusText = AppLocale.iosRetroarchStatusNeedsSync.getString(context);
    } else {
      statusText = AppLocale.iosRetroarchStatusSynced.getString(context);
    }

    return _buildIOSEmulatorCard(
      theme: theme,
      name: 'RetroArch',
      icon: Symbols.sports_esports_rounded,
      statusText: statusText,
      isLinked: isLinked,
      bookmarkKey: ExternalFolderAccess.defaultBookmarkKey,
      successMessage: AppLocale.iosRetroarchLinkSuccess.getString(context),
      trailingAction: SizedBox(
        height: 48.r,
        child: FilledButton.icon(
          onPressed: !isLinked ? null : _syncWithRetroArch,
          icon: Icon(Symbols.bolt_rounded, size: 20.r),
          label: Text(
            hasSynced
                ? AppLocale.iosEmuResync.getString(context)
                : AppLocale.iosEmuSync.getString(context),
            style: TextStyle(fontSize: 14.r),
          ),
        ),
      ),
    );
  }

  Widget _buildIOSRpcs3Section(ThemeData theme) {
    final isLinked = Rpcs3LibraryService.isLinked;
    final hasSynced = Rpcs3LibraryService.hasSyncedLibrary;
    final count = Rpcs3LibraryService.syncedGameCount;

    final String statusText;
    if (!isLinked) {
      statusText = Rpcs3LibraryLocale.statusNeedsLink(context);
    } else if (!hasSynced) {
      statusText = Rpcs3LibraryLocale.statusNeedsSync(context);
    } else {
      statusText = Rpcs3LibraryLocale.statusSynced(context, count);
    }

    return _buildIOSEmulatorCard(
      theme: theme,
      name: 'RPCS3',
      icon: Symbols.sports_esports_rounded,
      statusText: statusText,
      isLinked: isLinked,
      bookmarkKey: Rpcs3LibraryService.bookmarkKey,
      successMessage: '',
      onLinkPressed: _linkRpcs3DataFolder,
      trailingAction: SizedBox(
        height: 48.r,
        child: FilledButton.icon(
          onPressed: _linkingFolderKey == null ? _syncWithRpcs3 : null,
          icon: Icon(Symbols.bolt_rounded, size: 20.r),
          label: Text(
            hasSynced
                ? AppLocale.iosEmuResync.getString(context)
                : AppLocale.iosEmuSync.getString(context),
            style: TextStyle(fontSize: 14.r),
          ),
        ),
      ),
    );
  }

  Widget _buildIOSArmsx2Section(ThemeData theme) {
    final hasSynced = Armsx2LibraryService.hasSyncedLibrary;
    final isSaveLinked = ConfigService.linkedArmsx2SaveFolderPath != null;
    final statusText = hasSynced
        ? AppLocale.iosArmsx2StatusSynced.getString(context)
        : AppLocale.iosArmsx2StatusNeedsSync.getString(context);

    return _buildIOSEmulatorCard(
      theme: theme,
      name: 'ARMSX2',
      icon: Symbols.stadia_controller_rounded,
      statusText: statusText,
      isLinked: isSaveLinked,
      bookmarkKey: ConfigService.armsx2NeoSyncBookmarkKey,
      successMessage: '',
      onLinkPressed: () => _linkNeoSyncSaveFolder(
        bookmarkKey: ConfigService.armsx2NeoSyncBookmarkKey,
        emulatorName: 'ARMSX2',
      ),
      trailingAction: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 48.r,
              child: FilledButton.icon(
                onPressed: _syncWithArmsx2,
                icon: Icon(Symbols.bolt_rounded, size: 20.r),
                label: Text(
                  hasSynced
                      ? AppLocale.iosEmuResync.getString(context)
                      : AppLocale.iosEmuSync.getString(context),
                  style: TextStyle(fontSize: 14.r),
                ),
              ),
            ),
          ),
          SizedBox(width: 10.r),
          Expanded(
            child: SizedBox(
              height: 48.r,
              child: OutlinedButton.icon(
                onPressed: _configureArmsx2Launch,
                icon: Icon(Symbols.rocket_launch_rounded, size: 20.r),
                label: Text(
                  AppLocale.configureLaunch.getString(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.r),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIOSMeloNXSection(ThemeData theme) {
    final hasSynced = MelonxLibraryService.hasSyncedLibrary;
    final isSaveLinked = ConfigService.linkedMelonxSaveFolderPath != null;

    final statusText = hasSynced
        ? AppLocale.iosMelonxStatusSynced.getString(context)
        : AppLocale.iosMelonxStatusNeedsSync.getString(context);

    return _buildIOSEmulatorCard(
      theme: theme,
      name: 'MeloNX',
      icon: Symbols.videogame_asset_rounded,
      statusText: statusText,
      isLinked: isSaveLinked,
      bookmarkKey: ConfigService.melonxNeoSyncBookmarkKey,
      successMessage: '',
      onLinkPressed: () => _linkNeoSyncSaveFolder(
        bookmarkKey: ConfigService.melonxNeoSyncBookmarkKey,
        emulatorName: 'MeloNX',
      ),
      trailingAction: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 48.r,
              child: FilledButton.icon(
                onPressed: _syncWithMeloNX,
                icon: Icon(Symbols.bolt_rounded, size: 20.r),
                label: Text(
                  hasSynced
                      ? AppLocale.iosEmuResync.getString(context)
                      : AppLocale.iosEmuSync.getString(context),
                  style: TextStyle(fontSize: 14.r),
                ),
              ),
            ),
          ),
          SizedBox(width: 10.r),
          Expanded(
            child: SizedBox(
              height: 48.r,
              child: OutlinedButton.icon(
                onPressed:
                    IosShortcutJitLaunchService.hasMeloNXShortcutInstaller
                    ? _configureMeloNXLaunch
                    : null,
                icon: Icon(Symbols.rocket_launch_rounded, size: 20.r),
                label: Text(
                  AppLocale.configureLaunch.getString(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.r),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIOSEmulatorCard({
    required ThemeData theme,
    required String name,
    required IconData icon,
    required String statusText,
    required bool isLinked,
    required String bookmarkKey,
    required String successMessage,
    bool showLinkButton = true,
    Future<void> Function()? onLinkPressed,
    Widget? trailingAction,
  }) {
    final isLinkingThis = _linkingFolderKey == bookmarkKey;
    final isAnyLinkInFlight = _linkingFolderKey != null;

    final linkButton = SizedBox(
      height: 48.r,
      child: OutlinedButton.icon(
        onPressed: isAnyLinkInFlight
            ? null
            : () async {
                if (onLinkPressed != null) {
                  await onLinkPressed();
                } else {
                  await _linkExternalFolder(
                    bookmarkKey: bookmarkKey,
                    successMessage: successMessage,
                  );
                }
              },
        icon: isLinkingThis
            ? SizedBox(
                width: 18.r,
                height: 18.r,
                child: const CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                isLinked ? Symbols.link_rounded : Symbols.add_link_rounded,
                size: 20.r,
              ),
        label: Text(
          isLinked
              ? AppLocale.iosEmuChangeFolder.getString(context)
              : AppLocale.iosEmuLinkFolder.getString(context),
          style: TextStyle(fontSize: 14.r),
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4.r, vertical: 8.r),
      child: Container(
        padding: EdgeInsets.all(16.r),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.4,
          ),
          borderRadius: BorderRadius.circular(14.r),
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.2),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary, size: 24.r),
                SizedBox(width: 10.r),
                Text(
                  name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontSize: 16.r,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            SizedBox(height: 8.r),
            Text(
              statusText,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 13.r,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: 16.r),
            Row(
              children: [
                if (showLinkButton) Expanded(child: linkButton),
                if (showLinkButton && trailingAction != null)
                  SizedBox(width: 10.r),
                if (trailingAction != null) Expanded(child: trailingAction),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectRomFolder() async {
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );

    if (configProvider.config.romFolders.length >= 5) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.maxRomFoldersReached.getString(context),
          type: NotificationType.info,
        );
      }
      return;
    }

    try {
      String? selected;

      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (isTV) {
          if (mounted) selected = await TvDirectoryPicker.show(context);
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            selected = uri?.toString();
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' && mounted) {
              selected = await TvDirectoryPicker.show(context);
            }
          }
        }
      } else if (Platform.isIOS) {
        selected = await ConfigService.getDefaultIOSRomsFolder();
        if (configProvider.config.romFolders.contains(selected)) {
          if (mounted) {
            AppNotification.showNotification(
              context,
              'Already using the internal roms folder. Drop ROMs into it '
              'via the Files app under "On My iPhone > NeoStation > roms".',
              type: NotificationType.info,
            );
          }
          return;
        }
      } else {
        selected = await FilePicker.getDirectoryPath(
          dialogTitle: AppLocale.selectRomsFolder.getString(context),
        );
      }

      if (selected != null) {
        await configProvider.addRomFolder(selected);
        await _loadCurrentPaths();
      }
    } catch (e) {
      _log.e('ROM folder selection failed: $e');
    }
  }

  Future<void> _removeRomFolder(String path) async {
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.removeRomFolder.getString(context),
      body: AppLocale.removeRomFolderConfirmBody.getString(context),
      confirmLabel: AppLocale.removeRomFolder.getString(context),
      icon: Symbols.folder_delete_rounded,
    );
    if (!confirmed || !mounted) return;

    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    try {
      await configProvider.removeRomFolder(path);
      await _loadCurrentPaths();
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.romFolderRemoved.getString(context),
          type: NotificationType.info,
        );
      }
    } catch (e) {
      _log.e('Failed to remove ROM folder: $e');
    }
  }

  Future<void> _selectUserDataLocation() async {
    try {
      String? selected;

      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (!mounted) return;
        if (isTV) {
          selected = await TvDirectoryPicker.show(context);
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            if (uri != null) {
              final uriStr = uri.toString();
              final hasFiles = await PermissionService.hasAllFilesAccess();
              selected =
                  await UserDataLocationService.resolveAndroidUserDataPath(
                    uriStr,
                    hasAllFilesAccess: hasFiles,
                  ) ??
                  UserDataLocationService.safUriToRealPath(uriStr);
            }
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' && mounted) {
              selected = await TvDirectoryPicker.show(context);
            }
          }
        }
      } else {
        selected = await FilePicker.getDirectoryPath(
          dialogTitle: AppLocale.selectUserDataFolder.getString(context),
          initialDirectory: _currentUserDataPath,
        );
      }

      if (selected == null || !mounted) return;
      if (selected.endsWith(Platform.pathSeparator)) {
        selected = selected.substring(0, selected.length - 1);
      }

      final current = _currentUserDataPath;
      if (current == null || selected == current) return;

      final entryCount = await UserDataLocationService.countDirectoryEntries(
        selected,
      );
      if (!mounted) return;
      final proceed = await MoveUserDataDialog.show(
        context,
        fromPath: current,
        toPath: selected,
        destItemCount: entryCount,
      );
      if (!proceed || !mounted) return;

      await _migrateUserData(sourcePath: current, destPath: selected);
    } catch (e) {
      _log.e('User data location selection failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          '${AppLocale.migratingUserDataError.getString(context)}: $e',
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _migrateUserData({
    required String sourcePath,
    required String destPath,
  }) async {
    if (!mounted) return;
    String? migrationError;

    setState(() {
      _isMigrating = true;
      _migrationProgress = 0.0;
      _migrationFile = '';
    });

    try {
      final currentMediaPath = await ConfigService.getMediaPath();
      await UserDataLocationService.migrateData(
        sourceUserDataPath: sourcePath,
        sourceMediaPath: currentMediaPath,
        destPath: destPath,
        onProgress: (p, file) {
          if (mounted) {
            setState(() {
              _migrationProgress = p;
              _migrationFile = file;
            });
          }
        },
      );
      await UserDataLocationService.setCustomPath(destPath);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(PermissionCheckWrapper.setupCompletedKey, true);
    } catch (e) {
      migrationError = e.toString();
      _log.e('Migration failed: $e');
    }

    if (mounted) setState(() => _isMigrating = false);

    if (migrationError != null) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          '${AppLocale.migratingUserDataError.getString(context)}: $migrationError',
          type: NotificationType.error,
        );
      }
      return;
    }

    if (mounted) setState(() => _currentUserDataPath = destPath);

    if (mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const RestartRequiredDialog(),
      );
    }
  }

  int getItemCount() => _directoryItems.length;

  void selectItem(int index) {
    if (index < _directoryItems.length) {
      _handleItemTap(_directoryItems[index]);
    }
  }

  Widget _buildMigrationProgress(ThemeData theme) {
    if (!_isMigrating) return const SizedBox.shrink();
    final pct = _migrationProgress;
    final isCopying = pct < 0.5;
    return Container(
      margin: EdgeInsets.only(bottom: 12.r),
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isCopying
                    ? AppLocale.migratingUserData.getString(context)
                    : '${AppLocale.delete.getString(context)}...',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
              Text(
                '${(pct * 100).toInt()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.r),
          ClipRRect(
            borderRadius: BorderRadius.circular(4.r),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6.r,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
            ),
          ),
          if (_migrationFile.isNotEmpty) ...[
            SizedBox(height: 4.r),
            Text(
              _migrationFile,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildScanProgress(ThemeData theme, SqliteConfigProvider provider) {
    if (!provider.isScanning) return const SizedBox.shrink();
    return Container(
      margin: EdgeInsets.only(bottom: 12.r),
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                provider.scanStatus,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
              Text(
                '${(provider.scanProgress * 100).toInt()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.r),
          ClipRRect(
            borderRadius: BorderRadius.circular(4.r),
            child: LinearProgressIndicator(
              value: provider.totalSystemsToScan > 0
                  ? provider.scanProgress
                  : null,
              minHeight: 6.r,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
            ),
          ),
          if (provider.totalSystemsToScan > 0) ...[
            SizedBox(height: 4.r),
            Text(
              '${AppLocale.scanningSystem.getString(context)} ${provider.scannedSystemsCount} of ${provider.totalSystemsToScan}',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(
            title: AppLocale.configureDirectories.getString(context),
            subtitle: AppLocale.configureRomsFolder.getString(context),
          ),
          SizedBox(height: 24.h),
          const Center(child: CircularProgressIndicator()),
        ],
      );
    }

    return Consumer<SqliteConfigProvider>(
      builder: (context, configProvider, child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SettingsTitle(
              title: AppLocale.configureDirectories.getString(context),
              subtitle: AppLocale.configureRomsFolder.getString(context),
            ),
            SizedBox(height: 12.r),
            _buildMigrationProgress(theme),
            _buildScanProgress(theme, configProvider),
            _buildEsdeProgress(theme),
            _buildEsdeResultSummary(theme),
            Expanded(
              child: Builder(
                builder: (context) {
                  final visualRows = <Map<String, dynamic>>[];

                  for (final card in _iosEmulatorCards(theme)) {
                    visualRows.add({'card': card});
                  }

                  for (var i = 0; i < _directoryItems.length; i++) {
                    if (i == 2) {
                      visualRows.add({
                        'header': AppLocale.romDirectories.getString(context),
                      });
                    }
                    if (i == _esdeSectionStart) {
                      visualRows.add({
                        'header': AppLocale.esdeImport.getString(context),
                      });
                    }
                    visualRows.add({'nav': i});
                  }
                  _ensureKeys(_directoryItems.length);

                  return ListView.builder(
                    controller: _scrollController,
                    physics: const ClampingScrollPhysics(),
                    itemCount: visualRows.length,
                    itemBuilder: (context, visualIndex) {
                      final row = visualRows[visualIndex];
                      if (row.containsKey('card')) {
                        return row['card'] as Widget;
                      }
                      if (row.containsKey('header')) {
                        return SettingsSectionHeader(
                          label: row['header'] as String,
                        );
                      }

                      final navIndex = row['nav'] as int;
                      final item = _directoryItems[navIndex];
                      final isSelected =
                          widget.isContentFocused &&
                          widget.selectedContentIndex == navIndex;

                      final isRemoveItem = item['action'] == 'remove_rom';
                      final isUserData = item['action'] == 'user_data';
                      final isEsdeDisabled = _isEsdeDisabled(
                        item['action'] as String,
                      );
                      final borderColor = isSelected
                          ? (isRemoveItem
                                ? theme.colorScheme.error
                                : theme.colorScheme.primary)
                          : theme.colorScheme.outline.withValues(alpha: 0);

                      return Opacity(
                        key: _itemKeys[navIndex],
                        opacity: isEsdeDisabled ? 0.4 : 1.0,
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected && isRemoveItem
                                ? theme.colorScheme.error.withValues(
                                    alpha: 0.08,
                                  )
                                : theme.cardColor.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(12.r),
                            border: Border.all(
                              color: borderColor,
                              width: isSelected ? 2.r : 1.r,
                            ),
                          ),
                          margin: EdgeInsets.only(bottom: 8.r),
                          child: InkWell(
                            onTap: isEsdeDisabled
                                ? null
                                : () {
                                    SfxService().playNavSound();
                                    _handleItemTap(item);
                                  },
                            borderRadius: BorderRadius.circular(12.r),
                            canRequestFocus: false,
                            focusColor: Colors.transparent,
                            hoverColor: Colors.transparent,
                            highlightColor: Colors.transparent,
                            splashColor: Colors.transparent,
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 12.r,
                                vertical: 8.r,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        _iconFor(item['action'] as String),
                                        color: isSelected
                                            ? (isRemoveItem
                                                  ? theme.colorScheme.error
                                                  : theme.colorScheme.primary)
                                            : theme.colorScheme.onSurface,
                                        size: 20.r,
                                      ),
                                      SizedBox(width: 12.r),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              isRemoveItem
                                                  ? (item['title'] as String)
                                                  : (item['title'] as String)
                                                        .getString(context),
                                              style: theme.textTheme.titleSmall
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: isRemoveItem
                                                        ? 10.r
                                                        : 12.r,
                                                    color: isSelected
                                                        ? (isRemoveItem
                                                              ? theme
                                                                    .colorScheme
                                                                    .error
                                                              : theme
                                                                    .colorScheme
                                                                    .primary)
                                                        : theme
                                                              .colorScheme
                                                              .onSurface,
                                                    fontFamily: isRemoveItem
                                                        ? 'monospace'
                                                        : null,
                                                  ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            SizedBox(height: 2.r),
                                            Text(
                                              (item['subtitle'] as String)
                                                  .getString(context),
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color:
                                                        isSelected &&
                                                            isRemoveItem
                                                        ? theme
                                                              .colorScheme
                                                              .error
                                                              .withValues(
                                                                alpha: 0.7,
                                                              )
                                                        : theme
                                                              .colorScheme
                                                              .onSurface
                                                              .withValues(
                                                                alpha: 0.6,
                                                              ),
                                                    fontSize: 9.r,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (isRemoveItem)
                                        SettingsActionButton(
                                          icon: Symbols.delete_outline_rounded,
                                          selected: isSelected,
                                          isDestructive: true,
                                        )
                                      else if (item['action'] == 'add_rom')
                                        SettingsActionButton(
                                          icon: Symbols.add_rounded,
                                          selected: isSelected,
                                        )
                                      else if (item['action'] == 'rescan')
                                        SettingsActionButton(
                                          icon: Symbols.refresh_rounded,
                                          selected: isSelected,
                                        )
                                      else if (isUserData)
                                        SettingsActionButton(
                                          icon: Symbols.edit_rounded,
                                          selected: isSelected,
                                        )
                                      else if (item['action'] ==
                                          'esde_select_folder')
                                        SettingsActionButton(
                                          icon: Symbols.folder_special_rounded,
                                          selected: isSelected,
                                        )
                                      else if (item['action'] ==
                                          'esde_run_import')
                                        SettingsActionButton(
                                          icon: Symbols.download_rounded,
                                          selected: isSelected,
                                        )
                                      else if (item['action'] == 'esde_reset')
                                        SettingsActionButton(
                                          icon: Symbols.restart_alt_rounded,
                                          selected: isSelected,
                                          isDestructive: true,
                                        ),
                                    ],
                                  ),
                                  if (item['action'] == 'esde_select_folder' &&
                                      _esdePath.trim().isNotEmpty) ...[
                                    SizedBox(height: 6.r),
                                    _buildPathChip(theme, _esdePath),
                                  ],
                                  if (isUserData &&
                                      _currentUserDataPath != null) ...[
                                    SizedBox(height: 6.r),
                                    Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 8.r,
                                        vertical: 4.r,
                                      ),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.primary
                                            .withValues(alpha: 0.06),
                                        borderRadius: BorderRadius.circular(
                                          6.r,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Symbols.folder_rounded,
                                            size: 11.r,
                                            color: theme.colorScheme.primary
                                                .withValues(alpha: 0.5),
                                          ),
                                          SizedBox(width: 6.r),
                                          Expanded(
                                            child: Text(
                                              _currentUserDataPath!,
                                              style: TextStyle(
                                                fontSize: 9.r,
                                                color: theme
                                                    .colorScheme
                                                    .onSurface
                                                    .withValues(alpha: 0.55),
                                                fontFamily: 'monospace',
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  IconData _iconFor(String action) {
    switch (action) {
      case 'user_data':
        return Symbols.folder_special_rounded;
      case 'rescan':
        return Symbols.refresh_rounded;
      case 'add_rom':
        return Symbols.folder_rounded;
      case 'remove_rom':
        return Symbols.folder_rounded;
      case 'esde_select_folder':
        return Symbols.folder_special_rounded;
      case 'esde_run_import':
        return Symbols.download_rounded;
      case 'esde_reset':
        return Symbols.restart_alt_rounded;
      default:
        return Symbols.folder_rounded;
    }
  }

  Widget _buildPathChip(ThemeData theme, String path) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6.r),
      ),
      child: Row(
        children: [
          Icon(
            Symbols.folder_rounded,
            size: 11.r,
            color: theme.colorScheme.primary.withValues(alpha: 0.5),
          ),
          SizedBox(width: 6.r),
          Expanded(
            child: Text(
              path,
              style: TextStyle(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                fontFamily: 'monospace',
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEsdeProgress(ThemeData theme) {
    if (!_esdeSupported || !_isImporting) return const SizedBox.shrink();
    final pct = _importProgress;
    return Container(
      margin: EdgeInsets.only(bottom: 12.r),
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                AppLocale.esdeImporting.getString(context),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
              Text(
                '${(pct * 100).toInt()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.r),
          ClipRRect(
            borderRadius: BorderRadius.circular(4.r),
            child: LinearProgressIndicator(
              value: pct > 0 ? pct : null,
              minHeight: 6.r,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
            ),
          ),
          if (_importLabel.isNotEmpty) ...[
            SizedBox(height: 4.r),
            Text(
              _importLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEsdeResultSummary(ThemeData theme) {
    if (!_esdeSupported) return const SizedBox.shrink();
    final r = _lastEsdeResult;
    if (r == null || _isImporting) return const SizedBox.shrink();
    return Container(
      margin: EdgeInsets.only(bottom: 12.r),
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12.r),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocale.esdeImportComplete.getString(context),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              fontSize: 11.r,
              color: theme.colorScheme.primary,
            ),
          ),
          SizedBox(height: 4.r),
          Text(
            '${AppLocale.esdeSummarySystemsMatched.getString(context)}: ${r.systemsMatched}   '
            '${AppLocale.esdeSummaryUnmatched.getString(context)}: ${r.systemsUnmatched}   '
            '${AppLocale.esdeSummarySkipped.getString(context)}: ${r.systemsSkipped}\n'
            '${AppLocale.esdeSummaryGamesImported.getString(context)}: ${r.gamesImported}   '
            '${AppLocale.esdeSummaryNoRomMatch.getString(context)}: ${r.gamesUnmatched}\n'
            '${AppLocale.esdeSummaryStatsUpdated.getString(context)}: ${r.statsUpdated}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 9.5.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
