import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/system_model.dart';

/// Console visibility is a user preference, independent of filesystem scans.
/// No game, BIOS, save, ROM folder or detected-system record is removed here.
class LibraryVisibilityService {
  LibraryVisibilityService(this._preferences);

  static const preferenceKey = 'neostation_console_libraries_v1';
  static const embeddedFolders = <String>{'ps2', 'ps3', 'gc', 'wii', 'ports'};
  static bool requiresPairingFor(Set<String> selectedFolders) =>
      selectedFolders.any(const {'ps2', 'ps3', 'gc', 'wii'}.contains);
  final SharedPreferences _preferences;

  static Future<LibraryVisibilityService> create() async =>
      LibraryVisibilityService(await SharedPreferences.getInstance());

  /// Fresh installations start with no selected consoles. Persist this pending
  /// state before any scan, so an interrupted first run cannot be mistaken for
  /// an old installation merely because native playlists were scanned.
  Future<LibraryVisibilitySelection> initialize({
    required bool existingInstallation,
    required Set<String> previouslyVisibleFolders,
    Set<String> existingLibraryFolders = const {},
  }) async {
    final saved = read();
    if (saved != null) return saved;
    final selection = LibraryVisibilitySelection(
      enabledFolders: existingInstallation
          ? previouslyVisibleFolders
          : const <String>{},
      setupCompleted: existingInstallation,
      existingInstallation: existingInstallation,
      legacyFolders: existingInstallation ? existingLibraryFolders : const {},
    );
    await save(selection);
    return selection;
  }

  LibraryVisibilitySelection? read() {
    final raw = _preferences.getString(preferenceKey);
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['version'] != 1 ||
          value['enabled'] is! List ||
          value['completed'] is! bool) {
        return null;
      }
      return LibraryVisibilitySelection(
        enabledFolders: (value['enabled'] as List).whereType<String>().toSet(),
        setupCompleted: value['completed'] as bool,
        // A completed document from a prior version is conservatively an
        // upgrade. A pending first install must remain fresh across scans.
        existingInstallation: value['existingInstallation'] is bool
            ? value['existingInstallation'] as bool
            : value['completed'] as bool,
        legacyFolders: value['legacy'] is List
            ? (value['legacy'] as List).whereType<String>().toSet()
            : (value['enabled'] as List).whereType<String>().toSet(),
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> save(LibraryVisibilitySelection selection) async {
    // A single value keeps the completion flag and the selection consistent.
    final enabled = selection.enabledFolders.toList()..sort();
    final legacy = selection.legacyFolders.toList()..sort();
    final persisted = await _preferences.setString(
      preferenceKey,
      jsonEncode({
        'version': 1,
        'completed': selection.setupCompleted,
        'existingInstallation': selection.existingInstallation,
        'enabled': enabled,
        'legacy': legacy,
      }),
    );
    if (!persisted) {
      await _preferences.reload();
      throw StateError('Library visibility persistence failed');
    }
  }

  static Future<LibraryVisibilitySelection?> readSavedSelection() async =>
      (await create()).read();
}

class LibraryVisibilitySelection {
  LibraryVisibilitySelection({
    required Set<String> enabledFolders,
    required this.setupCompleted,
    this.existingInstallation = false,
    Set<String> legacyFolders = const {},
  }) : enabledFolders = Set.unmodifiable(enabledFolders),
       legacyFolders = Set.unmodifiable(legacyFolders);

  final Set<String> enabledFolders;
  final bool setupCompleted;
  final bool existingInstallation;
  final Set<String> legacyFolders;

  /// Regional names share one chooser switch while keeping both existing DB
  /// identities and their file paths intact.
  static Set<String> consoleFolders(String folderName) =>
      folderName == 'md' || folderName == 'genesis'
      ? const {'md', 'genesis'}
      : {folderName};

  static List<SystemModel> groupConsoleChoices(List<SystemModel> systems) {
    final result = systems
        .where((system) => system.folderName != 'genesis')
        .toList();
    final megaDrive = result.indexWhere((system) => system.folderName == 'md');
    final genesis = systems.where((system) => system.folderName == 'genesis');
    if (megaDrive >= 0) {
      result[megaDrive] = result[megaDrive].copyWith(
        realName: 'Sega Mega Drive / Genesis',
      );
    } else if (genesis.isNotEmpty) {
      result.add(genesis.first.copyWith(realName: 'Sega Mega Drive / Genesis'));
    }
    return result;
  }

  bool isConsoleEnabled(String folderName) =>
      consoleFolders(folderName).any(enabledFolders.contains);

  LibraryVisibilitySelection withConsoleEnabled(
    String folderName,
    bool enabled,
  ) {
    final folders = enabledFolders.toSet();
    if (enabled) {
      folders.addAll(consoleFolders(folderName));
    } else {
      folders.removeAll(consoleFolders(folderName));
    }
    return LibraryVisibilitySelection(
      enabledFolders: folders,
      setupCompleted: setupCompleted,
      existingInstallation: existingInstallation,
      legacyFolders: legacyFolders,
    );
  }

  bool isVisible(String folderName) {
    if (folderName == 'all' || folderName == 'favorites') {
      return enabledFolders.isNotEmpty;
    }
    return enabledFolders.contains(folderName);
  }

  /// Physical-console visibility belongs to this selection after migration.
  /// Keep legacy display flags untouched and honor them for virtual lists.
  Set<String> hiddenFolders({
    required Iterable<SystemModel> available,
    required Set<String> legacyHidden,
  }) => {
    ...legacyHidden.where((folder) => folder == 'all' || folder == 'favorites'),
    ...available
        .where((system) => !isVisible(system.folderName))
        .map((system) => system.folderName),
  };

  LibraryVisibilitySelection withEnabled(String folderName, bool enabled) =>
      LibraryVisibilitySelection(
        enabledFolders: enabled
            ? {...enabledFolders, folderName}
            : (enabledFolders.toSet()..remove(folderName)),
        setupCompleted: setupCompleted,
        existingInstallation: existingInstallation,
        legacyFolders: legacyFolders,
      );

  /// Selected empty libraries remain reachable for their Import button. This
  /// does not add fake game counts or mark their content as installed.
  List<SystemModel> exposeSelectedLibraries({
    required List<SystemModel> detected,
    required List<SystemModel> available,
  }) {
    final result = [...detected];
    final present = detected.map((system) => system.folderName).toSet();
    for (final system in available) {
      if (enabledFolders.contains(system.folderName) &&
          present.add(system.folderName)) {
        result.add(system);
      }
    }
    return result;
  }
}
