import 'dart:io';

import 'package:external_folder_access/external_folder_access.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:libretro_internal_bridge/libretro_internal_bridge.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/libretro_locale.dart';
import '../models/game_model.dart';
import '../models/system_model.dart';
import '../repositories/system_repository.dart';
import 'config_service.dart';
import 'libretro_core_catalog.dart';
import 'logger_service.dart';

class LibretroLaunchOutcome {
  const LibretroLaunchOutcome({
    required this.success,
    this.errorCode,
    this.technicalDetails = '',
  });

  final bool success;
  final String? errorCode;
  final String technicalDetails;
}

class LibretroImportResult {
  const LibretroImportResult({
    required this.imported,
    required this.rejected,
    this.importedPaths = const <String>[],
    this.systemFolder = '',
  });

  final int imported;
  final int rejected;
  final List<String> importedPaths;

  /// System folder the games were copied into (`roms/<systemFolder>`), the
  /// system to rescan afterwards.
  final String systemFolder;
}

class LibretroRetroArchCopy {
  const LibretroRetroArchCopy({
    required this.saves,
    required this.states,
    required this.system,
  });

  final int saves;
  final int states;
  final int system;
  int get total => saves + states + system;
}

/// Embedded libretro engine: launches games of the systems listed in
/// [LibretroCoreCatalog] inside NeoStation, imports games into
/// NeoStation's own Files-visible `roms` folder and copies RetroArch saves
/// on request. Nothing is ever moved out of, or written into, RetroArch's
/// folders.
abstract final class LibretroInternalService {
  static final _log = LoggerService.instance;
  static const String _corePreferencePrefix = 'libretro_core_v1.';
  static const String retroArchChoice = 'retroarch';
  static const String _retroArchImportKey = 'libretro-retroarch-import';
  static const int _maxSystemFileBytes = 512 * 1024 * 1024;

  static bool handlesSystem(String folderName) =>
      Platform.isIOS && LibretroCoreCatalog.handles(folderName);

  /// Canonical catalog key of a system (see
  /// [LibretroCoreCatalog.canonicalSystem]): a system copy named after an
  /// alias folder during a scan still resolves to its bound system.
  static String systemKey(SystemModel system) => LibretroCoreCatalog.canonicalSystem(
        id: system.id,
        folders: system.folders,
        folderName: system.folderName,
      );

  /// [handlesSystem] for a system model, through [systemKey].
  static bool handlesSystemModel(SystemModel system) => handlesSystem(systemKey(system));

  static Future<Directory> rootDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory(path.join(documents.path, 'Libretro'));
  }

  static Future<Directory> _child(String name) async =>
      Directory(path.join((await rootDirectory()).path, name));

  static Future<Directory> systemDirectory() => _child('System');
  static Future<Directory> savesDirectory() => _child('Saves');
  static Future<Directory> statesDirectory() => _child('States');
  static Future<Directory> configDirectory() => _child('Config');
  static Future<Directory> cheatsDirectory() => _child('Cheats');

  /// One directory per imported skin (`Skins/<id>`).
  static Future<Directory> skinsDirectory() => _child('Skins');

  /// Per-console frontend settings, written only by the native
  /// LibretroFrontendStore (`Config/Frontend/<console>.json`).
  static Future<Directory> frontendDirectory() async =>
      Directory(path.join((await configDirectory()).path, 'Frontend'));

  static Future<Directory> cacheDirectory() async {
    final caches = await getApplicationCacheDirectory();
    return Directory(path.join(caches.path, 'Libretro'));
  }

  static Future<void> ensureLayout() async {
    for (final directory in <Directory>[
      await rootDirectory(),
      await systemDirectory(),
      await savesDirectory(),
      await statesDirectory(),
      await configDirectory(),
      await frontendDirectory(),
      await cheatsDirectory(),
      await skinsDirectory(),
      await cacheDirectory(),
    ]) {
      await directory.create(recursive: true);
    }
  }

  static String _preferenceKey(String systemFolder, String romName) =>
      '$_corePreferencePrefix${systemFolder.toLowerCase()}/$romName';

  /// Core chosen for one game: a core id, [retroArchChoice], or null for
  /// the system default.
  static Future<String?> coreChoiceFor(String systemFolder, String romName) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_preferenceKey(systemFolder, romName));
  }

  static Future<void> setCoreChoice(String systemFolder, String romName, String? choice) async {
    final preferences = await SharedPreferences.getInstance();
    final key = _preferenceKey(systemFolder, romName);
    if (choice == null) {
      await preferences.remove(key);
    } else {
      await preferences.setString(key, choice);
    }
  }

  static Future<List<String>> _bundledCores() async {
    try {
      return await LibretroInternalBridge.availableCores();
    } catch (error) {
      _log.w('Embedded libretro cores unavailable: $error');
      return const <String>[];
    }
  }

  /// True when this game should run inside NeoStation: its system has an
  /// embedded core present in this build, the file is readable here, and
  /// the user did not switch the game to the RetroArch app.
  static Future<bool> shouldLaunchEmbedded(SystemModel system, GameModel game) async {
    final key = systemKey(system);
    if (!handlesSystem(key)) return false;
    final romPath = game.romPath;
    if (romPath == null || romPath.isEmpty || !await File(romPath).exists()) return false;
    final choice = await coreChoiceFor(key, game.romname);
    if (choice == retroArchChoice) return false;
    final coreId = _resolveCoreId(key, choice);
    return coreId != null && (await _bundledCores()).contains(coreId);
  }

  static String? _resolveCoreId(String systemFolder, String? choice) {
    final binding = LibretroCoreCatalog.bindingFor(systemFolder);
    if (binding == null) return null;
    final allowed = <String>[binding.coreId, ...binding.alternatives];
    return choice != null && allowed.contains(choice) ? choice : binding.coreId;
  }

  static Future<LibretroLaunchOutcome> launch({
    required SystemModel system,
    required GameModel game,
    required Locale locale,
  }) async {
    final key = systemKey(system);
    final binding = LibretroCoreCatalog.bindingFor(key);
    final console = LibretroCoreCatalog.consoleFor(key);
    final romPath = game.romPath;
    if (binding == null || console == null || romPath == null) {
      return const LibretroLaunchOutcome(success: false, errorCode: 'LIBRETRO_INVALID_REQUEST');
    }
    final choice = await coreChoiceFor(key, game.romname);
    final coreId = _resolveCoreId(key, choice)!;
    final core = LibretroCoreCatalog.cores[coreId]!;
    await ensureLayout();
    final biosDirectory = await systemDirectory();
    if (core.biosAnyOf.isNotEmpty) {
      var found = false;
      for (final name in core.biosAnyOf) {
        if (await File(path.join(biosDirectory.path, name)).exists()) {
          found = true;
          break;
        }
      }
      if (!found) {
        return LibretroLaunchOutcome(
          success: false,
          errorCode: 'LIBRETRO_BIOS_MISSING',
          technicalDetails: core.biosAnyOf.join(', '),
        );
      }
    }
    final request = <String, Object?>{
      'coreId': coreId,
      'contentPath': path.normalize(romPath),
      'gameTitle': game.name,
      'console': console.id,
      'consoleName': console.name,
      'gameKey': '$key/${game.romname}',
      'systemDirectory': biosDirectory.path,
      'saveDirectory': (await savesDirectory()).path,
      'stateDirectory': (await statesDirectory()).path,
      'optionsDirectory': (await configDirectory()).path,
      'cheatsDirectory': (await cheatsDirectory()).path,
      'cacheDirectory': (await cacheDirectory()).path,
      'skinsDirectory': (await skinsDirectory()).path,
      'frontendDirectory': (await frontendDirectory()).path,
      'consoleGeometry': LibretroCoreCatalog.consoleGeometry(),
      'uiLocale': locale.toLanguageTag(),
      'retroLanguage': LibretroLocale.retroLanguage(locale),
      'uiText': LibretroLocale.nativeUI(locale),
      'optionDefaults': core.optionDefaults,
      'noJitOverrides': core.noJitOverrides,
      'lockedOptions': core.lockedOptions,
      'coreSettings': LibretroLocale.coreSettings(locale, core),
      'achievementsAllowed': binding.achievementsConsoleId > 0,
      'achievementsConsoleId': binding.achievementsConsoleId,
      'preferredHardwareContext': core.preferredHardwareContext,
    };
    try {
      final result = await LibretroInternalBridge.launch(request);
      if (result['success'] == true) {
        _log.i(
          'Embedded libretro running core=$coreId '
          '(${result['libraryName']} ${result['libraryVersion']}, '
          'renderer=${result['hardwareRendering']}) game=$romPath',
        );
        return const LibretroLaunchOutcome(success: true);
      }
      final log = result['log'];
      final details = <String>[
        'Core: $coreId',
        'Code: ${result['code'] ?? 'unknown'}',
        'Message: ${result['message'] ?? ''}',
        if (log is List && log.isNotEmpty) 'Log:\n${log.join('\n')}',
      ].join('\n');
      _log.e('Embedded libretro launch failed\n$details');
      return LibretroLaunchOutcome(
        success: false,
        errorCode: result['code']?.toString(),
        technicalDetails: details,
      );
    } catch (error) {
      _log.e('Embedded libretro launch error: $error');
      return LibretroLaunchOutcome(success: false, technicalDetails: '$error');
    }
  }

  /// NeoStation's own Files-visible ROM folder, registered like any library
  /// folder so imported games appear in the usual playlists.
  static Future<Directory> importDirectoryFor(String systemFolder) async {
    final roms = await ConfigService.getDefaultIOSRomsFolder();
    return Directory(path.join(roms, systemFolder.toLowerCase()));
  }

  /// Imports games for a system folder. The picker offers only the formats
  /// the system's cores open and the library scanner indexes for it
  /// ([systemExtensions], else the extensions the database lists for the
  /// system): a copied file the scanner ignores would never appear.
  static Future<LibretroImportResult> importGames(
    String systemFolder, {
    Iterable<String>? systemExtensions,
  }) async {
    final folder = systemFolder.toLowerCase();
    final indexed = systemExtensions ?? await _indexedExtensions(folder);
    final extensions = LibretroCoreCatalog.importExtensionsFor(folder, indexed: indexed).toList()..sort();
    if (extensions.isEmpty) {
      return LibretroImportResult(imported: 0, rejected: 0, systemFolder: folder);
    }
    final selection = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: extensions,
      withData: false,
      lockParentWindow: true,
    );
    if (selection == null) {
      return LibretroImportResult(imported: 0, rejected: 0, systemFolder: folder);
    }
    final destination = await importDirectoryFor(folder);
    await destination.create(recursive: true);
    var imported = 0;
    var rejected = 0;
    final importedPaths = <String>[];
    for (final file in selection.files) {
      final source = file.path;
      final extension = path.extension(file.name).replaceFirst('.', '').toLowerCase();
      if (source == null || !extensions.contains(extension)) {
        rejected++;
        continue;
      }
      try {
        final target = await _uniqueDestination(destination, file.name);
        final copied = await File(source).copy(target.path);
        final length = await copied.length();
        if (length == 0 || length != await File(source).length()) {
          await copied.delete();
          rejected++;
          continue;
        }
        imported++;
        importedPaths.add(copied.path);
        if (extension == 'cue' || extension == 'm3u') {
          await _copyReferencedTracks(File(source), destination);
        }
      } catch (error) {
        _log.w('Libretro import rejected ${file.name}: $error');
        rejected++;
      }
    }
    return LibretroImportResult(
      imported: imported,
      rejected: rejected,
      importedPaths: importedPaths,
      systemFolder: folder,
    );
  }

  /// [importGames] for a system model: its canonical folder and the
  /// extensions it carries from the database.
  static Future<LibretroImportResult> importGamesForSystem(SystemModel system) =>
      importGames(
        systemKey(system),
        systemExtensions: system.extensions.isEmpty ? null : system.extensions,
      );

  /// Imports games for one of the embedded consoles, even before it has any
  /// game: into [system] when the caller resolved it (from the provider's
  /// available systems), else into the console's import system.
  static Future<LibretroImportResult> importGamesForConsole(String console, {SystemModel? system}) async {
    final descriptor = LibretroCoreCatalog.consoles[console];
    if (descriptor == null) return const LibretroImportResult(imported: 0, rejected: 0);
    if (system != null) return importGamesForSystem(system);
    return importGames(descriptor.importSystem);
  }

  /// Extensions the scanner indexes for a system id (from its
  /// `assets/systems` definition, synced into the database); null when they
  /// cannot be read, in which case the picker keeps every core format.
  static Future<Set<String>?> _indexedExtensions(String systemId) async {
    try {
      final extensions = await SystemRepository.getExtensionsForSystem(systemId);
      return extensions.isEmpty ? null : extensions;
    } catch (error) {
      _log.w('Indexed extensions unavailable for $systemId: $error');
      return null;
    }
  }

  /// A cue sheet or playlist only works with the files it names; copy those
  /// that sit next to the picked file when the picker granted access.
  static Future<void> _copyReferencedTracks(File descriptor, Directory destination) async {
    final lines = await descriptor.readAsLines();
    final pattern = RegExp(r'FILE\s+"([^"]+)"', caseSensitive: false);
    final names = <String>{
      for (final line in lines)
        ...pattern.allMatches(line).map((match) => match.group(1)!),
      if (path.extension(descriptor.path).toLowerCase() == '.m3u')
        ...lines.map((line) => line.trim()).where((line) => line.isNotEmpty && !line.startsWith('#')),
    };
    for (final name in names) {
      final source = File(path.join(descriptor.parent.path, name));
      final target = File(path.join(destination.path, path.basename(name)));
      if (await source.exists() && !await target.exists()) await source.copy(target.path);
    }
  }

  static Future<File> _uniqueDestination(Directory directory, String name) async {
    final base = path.basenameWithoutExtension(name);
    final extension = path.extension(name);
    var candidate = File(path.join(directory.path, name));
    var index = 2;
    while (await candidate.exists()) {
      candidate = File(path.join(directory.path, '$base ($index)$extension'));
      index++;
    }
    return candidate;
  }

  /// Copies RetroArch's `saves`, `states` and `system` folders from a folder
  /// the user picks (normally On My iPhone › RetroArch). Existing NeoStation
  /// files are kept; RetroArch's files are only read.
  static Future<LibretroRetroArchCopy?> copyRetroArchData() async {
    final picked = await ExternalFolderAccess.pickAndActivateFolder(key: _retroArchImportKey);
    if (picked == null) return null;
    await ensureLayout();
    final root = Directory(picked);
    final saves = await _findFolder(root, 'saves');
    final states = await _findFolder(root, 'states');
    final system = await _findFolder(root, 'system');
    return LibretroRetroArchCopy(
      saves: saves == null ? 0 : await _copyTree(saves, await savesDirectory()),
      states: states == null ? 0 : await _copyTree(states, await statesDirectory()),
      system: system == null ? 0 : await _copyTree(system, await systemDirectory()),
    );
  }

  static Future<Directory?> _findFolder(Directory root, String name, {int depth = 3}) async {
    if (path.basename(root.path).toLowerCase() == name) return root;
    if (depth == 0) return null;
    try {
      final children = await root.list(followLinks: false).where((entry) => entry is Directory).cast<Directory>().toList();
      for (final child in children) {
        if (path.basename(child.path).toLowerCase() == name) return child;
      }
      for (final child in children) {
        final found = await _findFolder(child, name, depth: depth - 1);
        if (found != null) return found;
      }
    } catch (error) {
      _log.w('RetroArch folder scan skipped ${root.path}: $error');
    }
    return null;
  }

  static Future<int> _copyTree(Directory source, Directory destination) async {
    var copied = 0;
    await for (final entity in source.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = path.relative(entity.path, from: source.path);
      if (relative.split(path.separator).any((part) => part.startsWith('.'))) continue;
      final target = File(path.join(destination.path, relative));
      try {
        if (await target.exists() || await entity.length() > _maxSystemFileBytes) continue;
        await target.parent.create(recursive: true);
        await entity.copy(target.path);
        copied++;
      } catch (error) {
        _log.w('RetroArch copy skipped $relative: $error');
      }
    }
    return copied;
  }
}
