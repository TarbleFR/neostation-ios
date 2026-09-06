import '../services/neosync/neo_sync_save_policy.dart';
import '../services/dolphin_neosync_store.dart';
import 'neo_sync_models.dart';

/// A native save is one emulator file, a directory, or a verified battery/clock
/// pair. This identity is independent of a mutable game title or API ID.
class NeoSyncSaveUnitDescriptor {
  final String key;
  final String nativeRoot;
  final String memberPath;
  final String displayName;
  final String? detailName;
  final bool isState;
  final bool isDirectory;

  const NeoSyncSaveUnitDescriptor({
    required this.key,
    required this.nativeRoot,
    required this.memberPath,
    required this.displayName,
    this.detailName,
    required this.isState,
    required this.isDirectory,
  });

  String get nativePath =>
      nativeRoot.isEmpty ? memberPath : '$nativeRoot/$memberPath';
}

class NeoSyncCloudSaveUnit {
  final NeoSyncSaveUnitDescriptor descriptor;
  final List<NeoSyncFile> members;

  NeoSyncCloudSaveUnit({required this.descriptor, required List<NeoSyncFile> members})
      : members = List.unmodifiable(members) {
    if (members.isEmpty) throw ArgumentError('A save unit must have members');
  }

  String get key => descriptor.key;
  String get displayName => descriptor.displayName;
  String? get detailName => descriptor.detailName;
  int get totalBytes => members.fold(0, (sum, member) => sum + member.fileSize);
  DateTime get newestAt => members.map((member) =>
      member.fileModifiedAt ?? member.uploadedAt).reduce((a, b) => a.isAfter(b) ? a : b);

  /// Keep every object when old uploads overlap. A group is not an assertion
  /// that its contents are complete or interchangeable; restore validates them.
  bool get hasConflictingMembers {
    final seen = <String, NeoSyncFile>{};
    for (final member in members) {
      final path = NeoSyncSaveUnits.describe(member.sourceSavePath,
          gameName: member.gameName).memberPath;
      final previous = seen[path];
      if (previous != null && (previous.fileSize != member.fileSize ||
          previous.checksum == null || member.checksum == null ||
          previous.checksum!.toLowerCase() != member.checksum!.toLowerCase())) {
        return true;
      }
      seen[path] = member;
    }
    return false;
  }
}

class NeoSyncLocalSaveUnit {
  final NeoSyncSaveUnitDescriptor descriptor;
  final List<LocalSaveFile> members;

  NeoSyncLocalSaveUnit({required this.descriptor, required List<LocalSaveFile> members})
      : members = List.unmodifiable(members) {
    if (members.isEmpty) throw ArgumentError('A save unit must have members');
  }

  String get key => descriptor.key;
  String get displayName => descriptor.displayName;
  String? get detailName => descriptor.detailName;
  int get totalBytes => members.fold(0, (sum, member) => sum + member.fileSize);
  DateTime get newestAt => members.map((member) => member.lastModified)
      .reduce((a, b) => a.isAfter(b) ? a : b);
  bool get isSynced => members.every((member) => member.isSynced);
}

/// Shared by the account list, per-game status and whole-save actions. Native
/// directory boundaries and verified companion pairs determine membership;
/// names such as PARAM.SFO alone do not.
class NeoSyncSaveUnits {
  static List<NeoSyncCloudSaveUnit> cloud(Iterable<NeoSyncFile> files) {
    final candidates = files.where((file) =>
        file.saveKind == NeoSyncSaveKind.save).toList();
    final companions = _rtcCompanions(candidates.map((file) => file.sourceSavePath));
    final buckets = <String, List<NeoSyncFile>>{};
    final descriptors = <String, NeoSyncSaveUnitDescriptor>{};
    for (final file in candidates) {
      var descriptor = companions[NeoSyncSavePolicy.unwrap(file.sourceSavePath)] ??
          describe(file.sourceSavePath,
          gameName: file.gameName, fallbackKey: 'file:${file.id}');
      if (file.dolphinTarget != null) {
        descriptor = NeoSyncSaveUnitDescriptor(
          key: descriptor.key, nativeRoot: descriptor.nativeRoot,
          memberPath: descriptor.memberPath, displayName: file.displayName,
          detailName: file.dolphinDetailName, isState: descriptor.isState,
          isDirectory: false,
        );
      }
      descriptors.putIfAbsent(descriptor.key, () => descriptor);
      buckets.putIfAbsent(descriptor.key, () => []).add(file);
    }
    return [
      for (final entry in buckets.entries)
        NeoSyncCloudSaveUnit(descriptor: descriptors[entry.key]!, members: entry.value),
    ]..sort((a, b) => b.newestAt.compareTo(a.newestAt));
  }

  static List<NeoSyncLocalSaveUnit> local(Iterable<LocalSaveFile> files) {
    final candidates = files.toList();
    final companions = _rtcCompanions(candidates.map((file) => file.relativePath));
    final buckets = <String, List<LocalSaveFile>>{};
    final descriptors = <String, NeoSyncSaveUnitDescriptor>{};
    for (final file in candidates) {
      final source = NeoSyncSavePolicy.canonical(file.relativePath) != null
          ? file.relativePath : file.filePath;
      final descriptor = companions[NeoSyncSavePolicy.unwrap(source)] ?? describe(source,
          gameName: file.gameName, fallbackKey: file.filePath);
      descriptors.putIfAbsent(descriptor.key, () => descriptor);
      buckets.putIfAbsent(descriptor.key, () => []).add(file);
    }
    return [
      for (final entry in buckets.entries)
        NeoSyncLocalSaveUnit(descriptor: descriptors[entry.key]!, members: entry.value),
    ]..sort((a, b) => b.newestAt.compareTo(a.newestAt));
  }

  /// A clock file belongs to one matching battery save. Two different base
  /// formats, different cores or games are never merged by their display name.
  /// Presence of the pair is required; a filename alone cannot prove it.
  static Map<String, NeoSyncSaveUnitDescriptor> _rtcCompanions(
      Iterable<String> sourcePaths) {
    final stems = <String, Set<String>>{};
    for (final source in sourcePaths) {
      final key = NeoSyncSavePolicy.unwrap(source);
      final parsed = NeoSyncSavePolicy.canonical(key);
      if (parsed == null || parsed.isState || parsed.scope != 'game' ||
          !parsed.emulatorSlug.startsWith('retroarch.')) continue;
      final match = RegExp(r'\.(?:srm|sav|rtc)$', caseSensitive: false).firstMatch(key);
      if (match == null) continue;
      stems.putIfAbsent(key.substring(0, match.start), () => {}).add(key);
    }
    final result = <String, NeoSyncSaveUnitDescriptor>{};
    for (final entry in stems.entries) {
      final bases = entry.value.where((key) => !key.toLowerCase().endsWith('.rtc')).toList();
      final clocks = entry.value.where((key) => key.toLowerCase().endsWith('.rtc')).toList();
      if (bases.length != 1 || clocks.length != 1) continue;
      final parsed = NeoSyncSavePolicy.canonical(bases.single)!;
      final root = bases.single.substring(0, bases.single.lastIndexOf('/'));
      for (final key in [bases.single, clocks.single]) {
        result[key] = NeoSyncSaveUnitDescriptor(
          key: 'rtc-pair:${bases.single}', nativeRoot: root,
          memberPath: key.split('/').last,
          displayName: parsed.gameName!, isState: false, isDirectory: true,
        );
      }
    }
    return result;
  }

  static NeoSyncSaveUnitDescriptor describe(String sourcePath, {
    String gameName = '', String? fallbackKey,
  }) {
    final key = NeoSyncSavePolicy.unwrap(sourcePath);
    final parsed = NeoSyncSavePolicy.canonical(key);
    final leaf = key.split('/').last;
    final title = gameName.trim().isNotEmpty ? gameName.trim() : parsed?.gameName;
    final dolphin = DolphinSaveTarget.parse(key);
    if (dolphin != null) {
      return NeoSyncSaveUnitDescriptor(key: dolphin.cloudPath, nativeRoot: '',
        memberPath: dolphin.rawName, isState: dolphin.isState, isDirectory: false,
        displayName: dolphin.isState
            ? (title != null && title != dolphin.identity
                ? '$title · Slot ${int.parse(dolphin.slot)}' : dolphin.rawName)
            : (dolphin.system == 'gc' ? 'GC Memory cards' : 'Wii saves'),
        detailName: dolphin.isState ? dolphin.rawName : dolphin.identity,
      );
    }
    // Build 206 could label any shared PS2 state with the currently selected
    // game's name. Historical game_name is not an ownership proof. Keep every
    // cloud object intact and show its native state/slot, not that unsafe label.
    if (parsed?.system == 'ps2' && parsed?.emulatorSlug == 'armsx2' && parsed?.isState == true) {
      return NeoSyncSaveUnitDescriptor(key: key, nativeRoot: '',
        memberPath: parsed!.filePath, displayName: 'ARMSX2 · $leaf',
        detailName: parsed.filePath, isState: true, isDirectory: false);
    }
    final isState = parsed?.isState ?? RegExp(
      r'\.(?:state(?:\.?\d+|\.auto)?|p2s|ppst|ss\d+|st\d+|s\d{2})(?:\.gz)?$',
      caseSensitive: false,
    ).hasMatch(leaf);

    NeoSyncSaveUnitDescriptor directory(String identity, String root,
        String member, String fallbackTitle, {String? details,
        bool useGameTitle = true}) =>
      NeoSyncSaveUnitDescriptor(key: identity, nativeRoot: root,
        memberPath: member, displayName: useGameTitle
            ? (parsed?.gameName ?? title ?? fallbackTitle) : fallbackTitle,
        detailName: details, isState: false, isDirectory: true);

    if (!isState && parsed != null) {
      final parts = parsed.filePath.split('/');
      final namespace = '${parsed.system}/${parsed.emulatorSlug}';
      if (NeoSyncSavePolicy.isRpcs3Payload(key)) {
        final root = 'dev_hdd0/home/${parts[0]}/savedata/${parts[1]}';
        return directory('$namespace/$root', root, parts.skip(2).join('/'),
            parts[1], details: '${parts[0]} · ${parts[1]}');
      }
      if (const {'psp', 'pspminis'}.contains(parsed.system)) {
        final savedataIndex = parts.indexWhere((part) => part.toUpperCase() == 'SAVEDATA');
        final directoryIndex = savedataIndex >= 0 ? savedataIndex + 1 : 0;
        if (parts.length > directoryIndex + 1 &&
            RegExp(r'^[A-Z]{4}[0-9]{5}').hasMatch(parts[directoryIndex])) {
          final saveDirectory = parts[directoryIndex];
          final root = 'PSP/SAVEDATA/$saveDirectory';
          return directory('$namespace/$root', root,
              parts.skip(directoryIndex + 1).join('/'), saveDirectory,
              details: saveDirectory);
        }
      }
      if (parsed.system == 'ps2' && parts.length > 2 &&
          parts.first.toLowerCase() == 'memcards') {
        final root = 'memcards/${parts[1]}';
        return directory('$namespace/$root', root, parts.skip(2).join('/'),
            parts[1], useGameTitle: false);
      }
      if (parsed.system == 'switch' && parsed.scope == 'game') {
        if (parts.length > 4 && parts.first == 'profiles' &&
            RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(parts[1]) &&
            RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(parts[2]) &&
            RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(parts[3])) {
          final identity = parts.take(4).join('/').toLowerCase();
          final root = 'bis/user/save/${parts[3]}/0';
          return directory('$namespace/$identity', root,
              parts.skip(4).join('/'), parts[2], details: parts[3]);
        }
        // Historical uploads discarded the user/save identity. They can only
        // be grouped by their canonical game directory until provenance is
        // recovered. Never group by mutable API gameName metadata.
        final root = 'v2/saves/$namespace/game/${parsed.gameName}';
        return directory('$namespace/legacy/${parsed.gameName}', root,
            parsed.filePath, parsed.gameName!);
      }
    }

    // Legacy listings and local scans may still carry their complete native
    // path without the v2 envelope. Keep the same native directory boundaries.
    if (!isState && NeoSyncSavePolicy.safe(key.replaceFirst(RegExp(r'^/'), ''))) {
      final ps3 = RegExp(r'(?:^|/)(dev_hdd0/home/([0-9]{8})/savedata/([^/]+))/(.+)$',
          caseSensitive: false).firstMatch(key);
      if (ps3 != null) return directory('ps3/rpcs3/${ps3[1]}', ps3[1]!,
          ps3[4]!, ps3[3]!, details: '${ps3[2]} · ${ps3[3]}');
      final psp = RegExp(r'(?:^|/)(PSP/SAVEDATA/([^/]+))/(.+)$',
          caseSensitive: false).firstMatch(key);
      if (psp != null) return directory('psp/native/${psp[1]}', psp[1]!,
          psp[3]!, psp[2]!, details: psp[2]);
    }

    return NeoSyncSaveUnitDescriptor(
      key: parsed != null ? key : (fallbackKey ?? key), nativeRoot: '',
      memberPath: parsed?.filePath ?? leaf,
      displayName: isState && title != null && title != leaf
          ? '$title · $leaf' : (leaf.isNotEmpty ? leaf : (title ?? 'NeoSync')),
      isState: isState, isDirectory: false,
    );
  }
}
