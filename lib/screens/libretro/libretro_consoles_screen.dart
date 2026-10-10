import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/libretro_locale.dart';
import '../../models/system_model.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../repositories/system_repository.dart';
import '../../services/libretro_core_catalog.dart';
import '../../services/libretro_internal_service.dart';
import '../../services/logger_service.dart';
import '../../widgets/confirm_action_dialog.dart';
import 'libretro_library_actions.dart';
import 'libretro_skin_manager_screen.dart';

/// Settings › Folders › Embedded consoles (iOS): NeoStation's library (its
/// console folders, or a library moved into it), then every console the
/// embedded libretro engine runs, with game import and skin management. A
/// console needs no game to be listed, so the first games of a console (a
/// 3DS, for example) can be imported here, into one of the user's libraries.
class LibretroConsolesScreen extends StatefulWidget {
  const LibretroConsolesScreen({super.key});

  @override
  State<LibretroConsolesScreen> createState() => _LibretroConsolesScreenState();
}

class _LibretroConsolesScreenState extends State<LibretroConsolesScreen>
    with LibretroPageNavigation<LibretroConsolesScreen> {
  static final _log = LoggerService.instance;

  /// Console whose import is running; one import at a time.
  String? _importing;

  /// Library action running ('folders' or 'move'), and the move's progress.
  String? _libraryAction;
  int _moveDone = 0;
  int _moveTotal = 0;

  String _t(String key) => LibretroLocale.text(context, key);
  String _f(String key, Map<String, Object?> values) =>
      LibretroLocale.formatContext(context, key, values);

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// The system games of [console] are imported into, from the provider's
  /// systems (the database when they are not loaded yet).
  Future<SystemModel?> _importSystem(SqliteConfigProvider provider, LibretroConsole console) async {
    for (final system in provider.availableSystems) {
      if (system.id == console.importSystem) return system;
    }
    try {
      return await SystemRepository.getSystemById(console.importSystem);
    } catch (error) {
      _log.w('Libretro import system ${console.importSystem} unavailable: $error');
      return null;
    }
  }

  /// The system whose folder received the games ([LibretroImportResult.systemFolder]).
  Future<SystemModel?> _rescanTarget(
    SqliteConfigProvider provider,
    String systemFolder,
    SystemModel? imported,
  ) async {
    if (imported != null && LibretroInternalService.systemKey(imported) == systemFolder) return imported;
    for (final system in provider.availableSystems) {
      if (LibretroInternalService.systemKey(system) == systemFolder) return system;
    }
    try {
      return await SystemRepository.getSystemByFolderName(systemFolder);
    } catch (error) {
      _log.w('Libretro system folder $systemFolder unavailable: $error');
      return null;
    }
  }

  /// Imported games go to one of the user's library folders, then only the
  /// receiving system is rescanned. NeoStation's own `roms` folder received
  /// them only when no library folder was registered ([createdLibraryRoot]):
  /// it is registered first. Returns the failure detail when that
  /// registration did not hold.
  Future<String?> _refreshLibrary(
    SqliteConfigProvider provider,
    SystemModel? system,
    String? createdLibraryRoot,
  ) async {
    if (createdLibraryRoot != null && !provider.config.romFolders.contains(createdLibraryRoot)) {
      await provider.addRomFolder(createdLibraryRoot, scan: false);
      // addRomFolder reports a failed save through `error` only: never
      // announce games the library cannot list.
      if (!provider.config.romFolders.contains(createdLibraryRoot)) return provider.error ?? createdLibraryRoot;
    }
    if (system != null) {
      await provider.rescanSystemSilent(system);
    } else {
      await provider.scanSystems();
    }
    return null;
  }

  Future<void> _importGames(LibretroConsole console) async {
    if (_importing != null || _libraryAction != null) return;
    final provider = context.read<SqliteConfigProvider>();
    setState(() => _importing = console.id);
    try {
      final system = await _importSystem(provider, console);
      if (!mounted) return;
      final destination = await chooseLibretroImportDestination(
        context,
        systemFolder: system != null ? LibretroInternalService.systemKey(system) : console.importSystem,
        registeredRoots: provider.config.romFolders,
        folderAliases: system == null ? const <String>[] : <String>[system.folderName, ...system.folders],
      );
      if (destination.unavailable) {
        _notice(_t('importLibraryUnavailable'));
        return;
      }
      if (destination.cancelled || !mounted) return;
      pausePageNavigation();
      final result = await LibretroInternalService.importGamesForConsole(
        console.id,
        system: system,
        library: destination.library,
      );
      resumePageNavigation();
      if (result.imported > 0) {
        final target = await _rescanTarget(provider, result.systemFolder, system);
        final failure = await _refreshLibrary(provider, target, result.createdLibraryRoot);
        if (!mounted) return;
        _notice(
          failure == null
              ? _f('gamesImported', {'count': result.imported})
              : _f('importFailed', {'error': failure}),
        );
      }
      if (!mounted) return;
      if (result.alreadyPresent > 0) _notice(_f('importAlreadyPresent', {'count': result.alreadyPresent}));
      if (result.rejected > 0) _notice(_t('gamesRejected'));
    } catch (error) {
      _log.w('Libretro import failed for ${console.id}: $error');
      if (mounted) _notice(_f('importFailed', {'error': error}));
    } finally {
      resumePageNavigation();
      if (mounted) setState(() => _importing = null);
    }
  }

  Future<void> _createFolders() async {
    if (_importing != null || _libraryAction != null) return;
    final provider = context.read<SqliteConfigProvider>();
    setState(() => _libraryAction = 'folders');
    try {
      await createNeoStationConsoleFolders(provider);
      if (mounted) _notice(_t('libraryFoldersCreated'));
    } catch (error) {
      _log.w('Console folders not created: $error');
      if (mounted) _notice(_f('libraryActionFailed', {'error': error}));
    } finally {
      if (mounted) setState(() => _libraryAction = null);
    }
  }

  Future<void> _moveLibrary() async {
    if (_importing != null || _libraryAction != null) return;
    final provider = context.read<SqliteConfigProvider>();
    setState(() {
      _libraryAction = 'move';
      _moveDone = 0;
      _moveTotal = 0;
    });
    pausePageNavigation();
    try {
      final outcome = await moveLibraryIntoNeoStation(
        provider,
        confirm: (folder) async {
          resumePageNavigation();
          if (!mounted) return false;
          return ConfirmActionDialog.show(
            context,
            title: _t('libraryMoveConfirmTitle'),
            body: _f('libraryMoveConfirmBody', {'folder': folder}),
            confirmLabel: _t('libraryMoveConfirm'),
            icon: Icons.drive_file_move_outline,
          );
        },
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _moveDone = done;
              _moveTotal = total;
            });
          }
        },
      );
      if (outcome == null || !mounted) return;
      final move = outcome.move;
      _notice(
        move.total == 0
            ? _f('libraryMoveNothing', {'folder': outcome.source})
            : _f('libraryMoved', {
                'moved': move.moved + move.notRemoved,
                'kept': move.alreadyPresent,
                'failed': move.failed,
              }),
      );
    } catch (error) {
      _log.w('Library move failed: $error');
      if (mounted) _notice(_f('libraryActionFailed', {'error': error}));
    } finally {
      resumePageNavigation();
      if (mounted) setState(() => _libraryAction = null);
    }
  }

  Widget _buildLibrary(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _importing != null || _libraryAction != null;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.folder_special_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(child: Text(_t('libraryTitle'), style: theme.textTheme.titleMedium)),
                if (_libraryAction != null)
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _libraryAction == 'move' && _moveTotal > 0
                  ? _f('libraryMoving', {'done': _moveDone, 'total': _moveTotal})
                  : _t('libraryIntro'),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                LibretroFocusRing(
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('libretro-library-create-folders'),
                    onPressed: busy ? null : _createFolders,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: Text(_t('libraryCreateFolders')),
                  ),
                ),
                LibretroFocusRing(
                  child: OutlinedButton.icon(
                    key: const ValueKey('libretro-library-move'),
                    onPressed: busy ? null : _moveLibrary,
                    icon: const Icon(Icons.drive_file_move_outline),
                    label: Text(_t('libraryMove')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSkins(LibretroConsole console) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => LibretroSkinManagerScreen(console: console.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return libretroPage(Scaffold(
      appBar: libretroPageAppBar(context, _t('embeddedConsoles')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            // Every console is built (no lazy list), so the D-pad can always
            // reach the next one.
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                    child: Text(
                      _t('embeddedConsolesIntro'),
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  _buildLibrary(context),
                  for (final console in LibretroCoreCatalog.consoles.values) _buildConsole(context, console),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
  }

  Widget _buildConsole(BuildContext context, LibretroConsole console) {
    final theme = Theme.of(context);
    final importing = _importing == console.id;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sports_esports_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(child: Text(console.name, style: theme.textTheme.titleMedium)),
                if (importing)
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                LibretroFocusRing(
                  child: FilledButton.tonalIcon(
                    onPressed: _importing == null && _libraryAction == null ? () => _importGames(console) : null,
                    icon: const Icon(Icons.file_upload_outlined),
                    label: Text(_t('importGames')),
                  ),
                ),
                LibretroFocusRing(
                  child: OutlinedButton.icon(
                    onPressed: () => _openSkins(console),
                    icon: const Icon(Icons.palette_outlined),
                    label: Text(_t('skins')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
