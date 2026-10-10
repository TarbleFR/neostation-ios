import 'package:external_folder_access/external_folder_access.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../data/datasources/sqlite_config_service.dart';
import '../../l10n/libretro_locale.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../services/config_service.dart';
import '../../services/ios_rom_library_root_resolver.dart';
import '../../services/libretro_internal_service.dart';
import '../../services/neostation_rom_library.dart';
import 'libretro_skin_manager_screen.dart';

/// Where imported games go ([chooseLibretroImportDestination]).
class LibretroImportDestination {
  const LibretroImportDestination.library(LibretroImportLibrary this.library)
      : unavailable = false,
        cancelled = false;

  /// No library folder is registered: NeoStation's own `roms` folder.
  const LibretroImportDestination.neoStation()
      : library = null,
        unavailable = false,
        cancelled = false;

  /// Library folders are registered but none opens on this device: nothing
  /// is imported, so no second library is created next to the user's.
  const LibretroImportDestination.unavailable()
      : library = null,
        unavailable = true,
        cancelled = false;

  /// The user backed out of the choice.
  const LibretroImportDestination.cancelled()
      : library = null,
        unavailable = false,
        cancelled = true;

  final LibretroImportLibrary? library;
  final bool unavailable;
  final bool cancelled;
}

/// Imported games go to one of the user's own libraries, never to a second
/// one created next to it: with several libraries the user picks one, with
/// a single library it is used directly. NeoStation's `roms` folder is used
/// only when no library is registered at all.
Future<LibretroImportDestination> chooseLibretroImportDestination(
  BuildContext context, {
  required String systemFolder,
  required List<String> registeredRoots,
  Iterable<String> folderAliases = const <String>[],
}) async {
  final libraries = await LibretroInternalService.importLibraries(
    systemFolder,
    registeredRoots: registeredRoots,
    folderAliases: folderAliases,
  );
  if (libraries.isEmpty) {
    return registeredRoots.any((root) => !root.startsWith('content://'))
        ? const LibretroImportDestination.unavailable()
        : const LibretroImportDestination.neoStation();
  }
  if (libraries.length == 1) return LibretroImportDestination.library(libraries.single);
  if (!context.mounted) return const LibretroImportDestination.cancelled();
  final chosen = await Navigator.of(context).push<LibretroImportLibrary>(
    MaterialPageRoute<LibretroImportLibrary>(builder: (_) => LibretroImportLibraryScreen(libraries: libraries)),
  );
  return chosen == null ? const LibretroImportDestination.cancelled() : LibretroImportDestination.library(chosen);
}

/// A folder as the user sees it in Files: the part after the app's
/// Documents folder ("roms › 3ds"), else its last three folders.
String libretroLibraryLocation(String directory) {
  final normalized = path.posix.normalize(directory);
  final documents = normalized.lastIndexOf('/Documents/');
  final segments = (documents >= 0 ? normalized.substring(documents + '/Documents/'.length) : normalized)
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList();
  final shown = documents >= 0 || segments.length <= 3 ? segments : segments.sublist(segments.length - 3);
  return shown.join(' › ');
}

/// The page that asks which library receives the imported games. Returns
/// the chosen [LibretroImportLibrary]; B or Back returns nothing.
class LibretroImportLibraryScreen extends StatefulWidget {
  const LibretroImportLibraryScreen({super.key, required this.libraries});

  final List<LibretroImportLibrary> libraries;

  @override
  State<LibretroImportLibraryScreen> createState() => _LibretroImportLibraryScreenState();
}

class _LibretroImportLibraryScreenState extends State<LibretroImportLibraryScreen>
    with LibretroPageNavigation<LibretroImportLibraryScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return libretroPage(Scaffold(
      appBar: libretroPageAppBar(context, LibretroLocale.text(context, 'importLibraryTitle')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                    child: Text(
                      LibretroLocale.text(context, 'importLibraryIntro'),
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  for (var index = 0; index < widget.libraries.length; index++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: LibretroFocusRing(
                        radius: 14,
                        child: OutlinedButton(
                          key: ValueKey('libretro-import-library-$index'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                            alignment: Alignment.centerLeft,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () => Navigator.of(context).pop(widget.libraries[index]),
                          child: Row(
                            children: [
                              Icon(Icons.folder_outlined, color: theme.colorScheme.primary),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(widget.libraries[index].name, style: theme.textTheme.titleMedium),
                                    const SizedBox(height: 2),
                                    Text(
                                      libretroLibraryLocation(widget.libraries[index].directory),
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
  }
}

/// Registers NeoStation's `roms` folder as a library folder. Throws when the
/// registration did not hold (the provider reports a failed save only
/// through its error): never announce games the library cannot list.
Future<String> registerNeoStationLibrary(SqliteConfigProvider provider) async {
  final roms = await ConfigService.getDefaultIOSRomsFolder();
  if (!provider.config.romFolders.contains(roms)) {
    await provider.addRomFolder(roms, scan: false);
    if (!provider.config.romFolders.contains(roms)) throw StateError(provider.error ?? roms);
  }
  return roms;
}

/// Creates one folder per console of the embedded engine in NeoStation's
/// `roms` folder and registers it. Returns the folders created.
Future<int> createNeoStationConsoleFolders(SqliteConfigProvider provider, {bool scan = true}) async {
  final roms = await ConfigService.getDefaultIOSRomsFolder();
  final created = await NeoStationRomLibrary.createConsoleFolders(roms);
  await registerNeoStationLibrary(provider);
  if (scan) await provider.scanSystems();
  return created;
}

/// Bookmark of the folder a library is moved from (deletions in it go
/// through its security scope).
const String libretroLibraryMoveBookmarkKey = 'library-move';

/// The outcome of [moveLibraryIntoNeoStation].
class LibretroLibraryMoveOutcome {
  const LibretroLibraryMoveOutcome({required this.source, required this.move});

  /// The folder the games came from, as shown to the user.
  final String source;
  final RomLibraryMove move;
}

/// Lets the user pick the folder of a library and moves its games into
/// NeoStation's `roms` folder, one folder per console. Once every game is in
/// NeoStation, the library folders registered inside the picked folder are
/// removed from the library: NeoStation no longer depends on them. Null when
/// the picker or [confirm] was cancelled.
Future<LibretroLibraryMoveOutcome?> moveLibraryIntoNeoStation(
  SqliteConfigProvider provider, {
  required Future<bool> Function(String folder) confirm,
  void Function(int done, int total)? onProgress,
}) async {
  final picked = await ExternalFolderAccess.pickAndActivateFolder(key: libretroLibraryMoveBookmarkKey);
  if (picked == null) return null;
  final systems =
      provider.availableSystems.isNotEmpty ? provider.availableSystems : await SqliteConfigService.loadAvailableSystems();
  final names = <String>{
    for (final system in systems) ...<String>[system.folderName, ...system.folders],
  };
  final source = await IosRomLibraryRootResolver.resolveRetroArchScanRoot(
    linkedRoot: picked,
    systemFolderNames: names,
  );
  if (!await confirm(libretroLibraryLocation(source))) return null;
  final roms = await ConfigService.getDefaultIOSRomsFolder();
  final move = await NeoStationRomLibrary.moveLibrary(
    sourceRoot: source,
    romsRoot: roms,
    consoleFolderNames: names,
    onProgress: onProgress,
    deleteSource: ExternalFolderAccess.deleteGameFile,
  );
  await registerNeoStationLibrary(provider);
  final pickedRoot = path.normalize(picked);
  final replaced = move.complete
      ? provider.config.romFolders.where((folder) {
          final normalized = path.normalize(folder);
          return normalized != path.normalize(roms) &&
              (normalized == pickedRoot || path.isWithin(pickedRoot, normalized));
        }).toList()
      : const <String>[];
  for (final folder in replaced) {
    await provider.removeRomFolder(folder);
  }
  if (replaced.isEmpty) await provider.scanSystems();
  if (move.complete) await ExternalFolderAccess.clearBookmark(key: libretroLibraryMoveBookmarkKey);
  return LibretroLibraryMoveOutcome(source: libretroLibraryLocation(source), move: move);
}
