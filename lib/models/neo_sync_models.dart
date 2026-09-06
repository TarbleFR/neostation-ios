import 'package:flutter/material.dart';

import 'dart:io';
// DOLPHIN_ISOLATION_BEGIN: neosync_presentation_imports
import '../services/dolphin_neosync_store.dart';
import '../services/neosync/neo_sync_save_policy.dart';
import '../utils/cloud_path_builder.dart';
// DOLPHIN_ISOLATION_END: neosync_presentation_imports

/// Configuration settings for the NeoSync cloud synchronization service.
///
/// Defines platform-specific folder paths for local save data tracking.
class NeoSyncConfig {
  /// Whether the global synchronization service is enabled.
  final bool sync;

  /// List of monitored save directories on Android devices.
  final List<String> androidSyncFolder;

  /// List of monitored save directories on Windows devices.
  final List<String> windowsSyncFolder;

  /// List of monitored save directories on Linux devices.
  final List<String> linuxSyncFolder;

  /// List of monitored save directories on macOS devices.
  final List<String> macosSyncFolder;

  /// List of monitored save directories on iOS devices.
  final List<String> iosSyncFolder;

  const NeoSyncConfig({
    required this.sync,
    required this.androidSyncFolder,
    required this.windowsSyncFolder,
    required this.linuxSyncFolder,
    required this.macosSyncFolder,
    required this.iosSyncFolder,
  });

  /// Creates a [NeoSyncConfig] from a JSON-compatible map.
  factory NeoSyncConfig.fromJson(Map<String, dynamic> json) {
    return NeoSyncConfig(
      sync:
          (json['sync'] ?? true).toString().toLowerCase() == 'true' ||
          (json['sync'] ?? 1).toString() == '1',
      androidSyncFolder: _parseList(json['android_sync_folder']),
      windowsSyncFolder: _parseList(json['windows_sync_folder']),
      linuxSyncFolder: _parseList(json['linux_sync_folder']),
      macosSyncFolder: _parseList(json['macos_sync_folder']),
      iosSyncFolder: _parseList(json['ios_sync_folder']),
    );
  }

  /// Internal helper to parse dynamic JSON values into a string list.
  static List<String> _parseList(dynamic list) {
    if (list == null) return [];
    if (list is String) return [list];
    if (list is List) return list.map((e) => e.toString()).toList();
    return [];
  }

  /// Converts the configuration into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'sync': sync,
      'android_sync_folder': androidSyncFolder,
      'windows_sync_folder': windowsSyncFolder,
      'linux_sync_folder': linuxSyncFolder,
      'macos_sync_folder': macosSyncFolder,
      'ios_sync_folder': iosSyncFolder,
    };
  }

  /// Returns the save folder list for the currently active operating system.
  List<String> getFoldersForCurrentPlatform() {
    if (Platform.isAndroid) return androidSyncFolder;
    if (Platform.isWindows) return windowsSyncFolder;
    if (Platform.isLinux) return linuxSyncFolder;
    if (Platform.isMacOS) return macosSyncFolder;
    if (Platform.isIOS) return iosSyncFolder;
    return [];
  }

  /// Static instance representing a default configuration.
  static const NeoSyncConfig empty = NeoSyncConfig(
    sync: true,
    androidSyncFolder: [],
    windowsSyncFolder: [],
    linuxSyncFolder: [],
    macosSyncFolder: [],
    iosSyncFolder: [],
  );
}

/// Metadata for a file stored on the NeoSync cloud server.
class NeoSyncFile {
  // DOLPHIN_ISOLATION_BEGIN: neosync_filename_regression
  /// Accept the filename spellings used by NeoSync listings. A storage path or
  /// game title must never be substituted for an operational cloud filename.
  static String _readFileName(Map<String, dynamic> json) {
    for (final key in ['file_name', 'filename', 'fileName']) {
      final value = json[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return '';
  }

  /// Server listings can split the basename from the original cloud path.
  /// A recovered origin drives display and native restoration. Transfers still
  /// address the server by its unchanged filename/id.
  String get presentationPath {
    if (verifiedSourcePath != null) return verifiedSourcePath!;
    final filename = fileName.replaceAll('\\', '/');
    if (filename.startsWith('v2/')) return filename;
    final stored = filePath.replaceAll('\\', '/');
    final match = RegExp(r'(?:^|/)(v2/(?:saves|states)/[a-zA-Z0-9_-]+/[^/]+/(?:game|shared)/.+)$')
        .firstMatch(stored);
    final candidate = match?.group(1);
    if (candidate != null &&
        !candidate.split('/').any((part) => part.isEmpty || part == '.' || part == '..') &&
        (filename.trim().isEmpty || candidate.split('/').last == filename)) {
      return candidate;
    }
    final structured = _structuredSourcePath;
    if (structured != null) return structured;
    // Keep the server's name/path unchanged for requests and exports. Relative
    // metadata is an identity source, not a replacement API filename.
    if (filename.isEmpty && stored.isNotEmpty) return stored;
    return filename;
  }

  /// The September 2026 service returns a native relative file_path with
  /// system_name/emulator/type, and may omit file_name entirely. Rebuild only
  /// the app's comparison key; never upload this key as the native wire path.
  String? get _structuredSourcePath {
    final system = systemName?.trim().toLowerCase();
    final engine = emulator?.trim().toLowerCase();
    final kind = type.toLowerCase();
    if (system == null || engine == null ||
        !RegExp(r'^[a-z0-9_-]+$').hasMatch(system) ||
        !RegExp(r'^[a-z0-9._-]+$').hasMatch(engine) ||
        !const {'save', 'state', 'shared', 'custom'}.contains(kind)) return null;
    var native = filePath.replaceAll('\\', '/');
    if (!NeoSyncSavePolicy.safe(native) || native.contains(':') ||
        native.startsWith('v2/')) return null;
    final suppliedName = fileName.replaceAll('\\', '/');
    if (suppliedName.isNotEmpty && suppliedName != native &&
        suppliedName != native.split('/').last) return null;
    final state = kind == 'state' || (kind == 'custom' && RegExp(
      r'\.(?:state(?:\.?[0-9]+|\.auto)?|p2s|ppst|savestate|ss[0-9]+|st[0-9]+|s[0-9]{2})(?:\.gz)?$',
      caseSensitive: false,
    ).hasMatch(NeoSyncSavePolicy.unwrap(native)));
    var shared = kind == 'shared' || scope == 'shared';

    if (engine == DolphinSaveTarget.emulator) {
      if (kind == 'custom') return null;
      // Dolphin snapshot filenames alone do not identify a Wii title or GCI
      // owner. Their native ID is preserved as a separate relative component.
      final parts = native.split('/');
      if ((!shared && parts.length != 2) || (shared && parts.length != 1)) {
        return null;
      }
      final candidate = CloudPathBuilder.build(system: system,
        emulatorSlug: engine, scope: shared ? 'shared' : 'game',
        gameName: shared ? null : parts.first,
        filePath: parts.last, isState: state);
      return DolphinSaveTarget.parse(candidate)?.cloudPath;
    }

    if (engine.startsWith('retroarch.')) {
      final parts = native.split('/');
      if (parts.length > 1 &&
          CloudPathBuilder.retroArchCoreSlug(parts.first) == engine) {
        native = parts.skip(1).join('/');
      }
    }
    if (system == 'ps2' && engine == 'armsx2') shared = true;
    if (!shared && engine.startsWith('retroarch.') && !state) {
      shared = (system == 'ps2' && (native.contains('/') ||
          NeoSyncSavePolicy.unwrap(native).toLowerCase().endsWith('.ps2'))) ||
          (const {'dc', 'dreamcast'}.contains(system) &&
           native.split('/').last.toLowerCase().contains('vmu_save'));
    }
    var owner = gameName;
    // The local RetroArch key uses the native ROM basename for a single save,
    // and the playlist title only for directory saves. Human titles can differ
    // from a ROM filename (region/revision), so using game_name loses equality.
    if (engine.startsWith('retroarch.') && !native.contains('/')) {
      final leaf = NeoSyncSavePolicy.unwrap(native);
      final dot = leaf.lastIndexOf('.');
      owner = dot > 0 ? leaf.substring(0, dot) : leaf;
    }
    if (!shared && (owner.trim().isEmpty || owner == '.' || owner == '..')) {
      return null;
    }
    final candidate = CloudPathBuilder.build(system: system,
      emulatorSlug: engine, scope: shared ? 'shared' : 'game',
      gameName: shared ? null : owner, filePath: native, isState: state);
    if (kind == 'custom') {
      // Older user-selected folders used type=custom. This is not proof that
      // arbitrary content is a save: require a native save format or a known
      // savedata/container path before reconstructing an owning engine key.
      final nativeSave = NeoSyncSavePolicy.classify(native) == NeoSyncSaveKind.save;
      final nativePs3 = NeoSyncSavePolicy.isRpcs3Payload(candidate);
      final nativeSwitch = system == 'switch' && engine == 'melonx' &&
          RegExp(r'^profiles/[0-9a-fA-F]{32}/01[0-9a-fA-F]{14}/[0-9a-fA-F]{16}/.+$')
              .hasMatch(native);
      final nativePs2 = system == 'ps2' && !state &&
          RegExp(r'^memcards/[^/]+/[^/]+/.+$').hasMatch(native);
      if (!nativeSave && !nativePs3 && !nativeSwitch && !nativePs2) return null;
    }
    return NeoSyncSavePolicy.canonical(candidate) != null ? candidate : null;
  }

  final String type;
  final String? systemName;
  final String? emulator;
  final String? gameHash;
  final String? scope;

  /// A new device may not have created its core directory yet. The service's
  /// native path can supply that directory only when both its metadata and
  /// complete remaining payload agree with the resolved canonical identity.
  String? get nativeRetroArchCoreFolder {
    final key = NeoSyncSavePolicy.canonical(sourceSavePath);
    final native = filePath.replaceAll('\\', '/');
    if (key == null || !key.emulatorSlug.startsWith('retroarch.') ||
        emulator?.trim().toLowerCase() != key.emulatorSlug ||
        systemName?.trim().toLowerCase() != key.system ||
        !NeoSyncSavePolicy.safe(native) || native.contains(':')) return null;
    final parts = native.split('/');
    if (parts.length < 2 ||
        CloudPathBuilder.retroArchCoreSlug(parts.first) != key.emulatorSlug ||
        NeoSyncSavePolicy.unwrap(parts.skip(1).join('/')) != key.filePath) return null;
    return parts.first;
  }

  DolphinSaveTarget? get dolphinTarget => DolphinSaveTarget.parse(presentationPath);

  /// A local playlist title is a UI fallback, never upload/restore metadata.
  final String? dolphinDisplayTitle;
  /// Recovered only from matching canonical metadata or an unambiguous local
  /// savedata hash. Never serialized or used as an API object identifier.
  final String? verifiedSourcePath;
  String get sourceSavePath {
    final key = presentationPath;
    if (NeoSyncSavePolicy.canonical(key) != null || key.contains('/')) return key;
    final stored = filePath.replaceAll('\\', '/');
    if (NeoSyncSavePolicy.unwrap(stored).split('/').last ==
        NeoSyncSavePolicy.unwrap(key) &&
        NeoSyncSavePolicy.classify(stored) == NeoSyncSaveKind.save) return stored;
    return key;
  }
  NeoSyncSaveKind get saveKind {
    if (verifiedSourcePath != null) return NeoSyncSaveKind.save;
    final kind = NeoSyncSavePolicy.classify(sourceSavePath);
    // Explicit Dolphin ownership must never fall through into a RetroArch
    // save just because a malformed/unresolved filename happens to end .sav.
    if (emulator?.trim().toLowerCase() == DolphinSaveTarget.emulator &&
        dolphinTarget == null && kind != NeoSyncSaveKind.foreign) {
      return NeoSyncSaveKind.unresolved;
    }
    return kind;
  }
  String get exportSavePath =>
      NeoSyncSavePolicy.rpcs3NativePath(sourceSavePath) ?? sourceSavePath;
  String? get ps3BundleKey {
    final p = NeoSyncSavePolicy.canonical(sourceSavePath);
    if (!NeoSyncSavePolicy.isRpcs3Payload(sourceSavePath)) return null;
    return '${p!.gameName}/${p.filePath.split('/').take(2).join('/')}';
  }
  NeoSyncFile withVerifiedSourcePath(String key) {
    final p = NeoSyncSavePolicy.canonical(key);
    final kind = NeoSyncSavePolicy.classify(key);
    final nativeSwitch = p != null && p.system == 'switch' &&
        p.scope == 'game' && !p.isState && kind != NeoSyncSaveKind.foreign;
    if (kind != NeoSyncSaveKind.save && !nativeSwitch) {
      throw const FormatException('Source is not a verified save path');
    }
    return NeoSyncFile(id: id, fileName: fileName, filePath: filePath,
      fileSize: fileSize, gameName: gameName, uploadedAt: uploadedAt,
      fileModifiedAt: fileModifiedAt, fileModifiedAtTimestamp: fileModifiedAtTimestamp,
      userId: userId, checksum: checksum, dolphinDisplayTitle: dolphinDisplayTitle,
      verifiedSourcePath: key, type: type, systemName: systemName,
      emulator: emulator, gameHash: gameHash, scope: scope);
  }

  NeoSyncFile withDolphinDisplayTitle(String? title) => NeoSyncFile(
    id: id, fileName: fileName, filePath: filePath, fileSize: fileSize,
    gameName: gameName, uploadedAt: uploadedAt, fileModifiedAt: fileModifiedAt,
    fileModifiedAtTimestamp: fileModifiedAtTimestamp, userId: userId,
    checksum: checksum, dolphinDisplayTitle: title, verifiedSourcePath: verifiedSourcePath,
    type: type, systemName: systemName, emulator: emulator,
    gameHash: gameHash, scope: scope,
  );

  static String _readGameName(Map<String, dynamic> json) {
    for (final key in ['game_name', 'gameName']) {
      final value = json[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return (json['game_name'] ?? '').toString();
  }

  bool get hasDolphinGameTitle {
    final target = dolphinTarget;
    final title = gameName.trim();
    return target != null && target.isState && title.isNotEmpty &&
        !{target.identity, target.rawName, target.objectName,
          target.rawName.split('.').first, fileName}.contains(title);
  }

  /// A title is shown only for Dolphin savestates. Internal cards have one
  /// stable label even when several games share the same native card.
  String get displayName {
    final target = dolphinTarget;
    if (target != null) {
      if (target.isState) {
        final title = dolphinDisplayTitle?.trim().isNotEmpty == true
            ? dolphinDisplayTitle!.trim()
            : (hasDolphinGameTitle ? gameName.trim() : '');
        return title.isNotEmpty
            ? '$title · Slot ${int.parse(target.slot)}' : target.rawName;
      }
      return target.system == 'gc' ? 'GC Memory cards' : 'Wii saves';
    }
    // PNG/SFO and extensionless files are constituent PlayStation savedata,
    // not screenshots or unrelated files. Add context only when its path proves
    // the console; never hide or group unrelated same-named files.
    final context = _playStationSaveContext;
    final basename = (fileName.trim().isNotEmpty ? fileName : filePath)
        .replaceAll('\\', '/').split('/').last;
    if (context != null && basename.isNotEmpty) return '$context · $basename';
    // Some historical listings retain only the leaf and human game metadata.
    // Preserve the component as a separate row when no bundle path is known.
    if (const {'SYSDATA', 'ICON0.PNG', 'PARAM.SFO', 'PIC1.PNG', 'PLAYDATA'}
            .contains(basename.toUpperCase()) &&
        gameName.trim().isNotEmpty &&
        !{basename.toUpperCase(), basename.split('.').first.toUpperCase()}
            .contains(gameName.trim().toUpperCase())) {
      return '${gameName.trim()} · $basename';
    }
    if (fileName.trim().isNotEmpty) return fileName;
    final segments = filePath.replaceAll('\\', '/').split('/')
        .where((segment) => segment.trim().isNotEmpty);
    if (segments.isNotEmpty) return segments.last;
    if (gameName.trim().isNotEmpty) return gameName.trim();
    return id.isNotEmpty ? 'NeoSync · $id' : 'NeoSync';
  }

  /// Kept secondary so the user can distinguish GC card regions/slots without
  /// presenting a game's title as the owner of a shared internal memory card.
  String? get dolphinDetailName {
    final target = dolphinTarget;
    if (target == null) return null;
    if (target.isState) return target.rawName;
    if (target.kind == 'raw') return target.rawName;
    if (target.kind == 'gci') return '${target.region} · ${target.slot} · ${target.identity}';
    return target.identity;
  }

  String? get _playStationSaveContext {
    final key = presentationPath;
    final canonical = RegExp(r'^v2/saves/(ps3|psp)/[^/]+/game/([^/]+)/')
        .firstMatch(key);
    if (canonical != null) {
      return '${canonical[1]!.toUpperCase()} · ${canonical[2]}';
    }
    final paths = [fileName, filePath];
    for (final value in paths) {
      final normalized = value.replaceAll('\\', '/');
      final psp = RegExp(r'(?:^|/)PSP/SAVEDATA/([^/]+)/', caseSensitive: false)
          .firstMatch(normalized);
      if (psp != null) return 'PSP · ${psp[1]}';
      final ps3 = RegExp(r'(?:^|/)dev_hdd0/home/[0-9]{8}/savedata/([^/]+)/', caseSensitive: false)
          .firstMatch(normalized);
      if (ps3 != null) return 'PS3 · ${ps3[1]}';
    }
    return null;
  }
  // DOLPHIN_ISOLATION_END: neosync_filename_regression

  /// Unique identifier for the file on the server.
  final String id;

  /// The physical filename of the save file.
  final String fileName;

  /// Relative path within the synchronization tree.
  final String filePath;

  /// Size of the file in bytes.
  final int fileSize;

  /// Human-readable name of the game associated with this save.
  final String gameName;

  /// Timestamp indicating when the file was uploaded to the cloud.
  final DateTime uploadedAt;

  /// The original modification date of the file at the time of upload.
  final DateTime? fileModifiedAt;

  /// Unix timestamp (milliseconds) representing the file modification date.
  final int? fileModifiedAtTimestamp;

  /// Unique identifier of the user who owns this file.
  final String userId;

  /// MD5/SHA checksum for verifying file integrity and detecting changes.
  final String? checksum;

  NeoSyncFile({
    required this.id,
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.gameName,
    required this.uploadedAt,
    this.fileModifiedAt,
    this.fileModifiedAtTimestamp,
    required this.userId,
    this.checksum,
    // DOLPHIN_ISOLATION_BEGIN: neosync_local_title_parameter
    this.dolphinDisplayTitle,
    this.verifiedSourcePath,
    this.type = '',
    this.systemName,
    this.emulator,
    this.gameHash,
    this.scope,
    // DOLPHIN_ISOLATION_END: neosync_local_title_parameter
  });

  /// Creates a [NeoSyncFile] from a JSON-compatible map.
  factory NeoSyncFile.fromJson(Map<String, dynamic> json) {
    final timestampRaw = json['file_modified_at_timestamp'];
    DateTime? fileModifiedAtFromTimestamp;
    int? finalTimestamp;

    if (timestampRaw != null) {
      finalTimestamp = int.tryParse(timestampRaw.toString());
      // DOLPHIN_ISOLATION_BEGIN: neosync_timestamp_units
      // Current uploads use milliseconds; historical listings can use Unix
      // seconds. Keep zero/ancient millisecond sentinel values unchanged.
      if (finalTimestamp != null && finalTimestamp >= 1000000000 &&
          finalTimestamp < 100000000000) {
        finalTimestamp *= 1000;
      }
      // DOLPHIN_ISOLATION_END: neosync_timestamp_units
      if (finalTimestamp != null) {
        fileModifiedAtFromTimestamp = DateTime.fromMillisecondsSinceEpoch(
          finalTimestamp,
          isUtc: true,
        );
      }
    }

    return NeoSyncFile(
      id: (json['id'] ?? '').toString(),
      // DOLPHIN_ISOLATION_BEGIN: neosync_filename_field
      fileName: _readFileName(json),
      // DOLPHIN_ISOLATION_END: neosync_filename_field
      filePath: (json['file_path'] ?? '').toString(),
      fileSize: int.tryParse((json['file_size'] ?? '0').toString()) ?? 0,
      // DOLPHIN_ISOLATION_BEGIN: neosync_game_title_field
      gameName: _readGameName(json),
      // DOLPHIN_ISOLATION_END: neosync_game_title_field
      // DOLPHIN_ISOLATION_BEGIN: neosync_timestamp_display
      uploadedAt:
          DateTime.tryParse((json['created_at'] ?? '').toString()) ??
          DateTime.tryParse((json['uploaded_at'] ?? '').toString()) ??
          fileModifiedAtFromTimestamp ??
          DateTime.now(),
      // DOLPHIN_ISOLATION_END: neosync_timestamp_display
      fileModifiedAt: fileModifiedAtFromTimestamp,
      fileModifiedAtTimestamp: finalTimestamp,
      userId: (json['user_id'] ?? '').toString(),
      checksum: (json['file_hash'] ?? json['checksum'])?.toString(),
      // DOLPHIN_ISOLATION_BEGIN: neosync_structured_metadata
      type: (json['type'] ?? '').toString(),
      systemName: (json['system_name'] ?? json['system_id'])?.toString(),
      emulator: (json['emulator'] ?? json['emulator_id'])?.toString(),
      gameHash: json['game_hash']?.toString(),
      scope: json['scope']?.toString(),
      // DOLPHIN_ISOLATION_END: neosync_structured_metadata
    );
  }

  /// Converts the file metadata into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'file_name': fileName,
      'file_path': filePath,
      'file_size': fileSize,
      'game_name': gameName,
      'created_at': uploadedAt.toIso8601String(),
      'file_modified_at_timestamp': fileModifiedAtTimestamp,
      'user_id': userId,
      'file_hash': checksum,
      // DOLPHIN_ISOLATION_BEGIN: neosync_structured_metadata
      if (type.isNotEmpty) 'type': type,
      if (systemName != null) 'system_name': systemName,
      if (emulator != null) 'emulator': emulator,
      if (gameHash != null) 'game_hash': gameHash,
      if (scope != null) 'scope': scope,
      // DOLPHIN_ISOLATION_END: neosync_structured_metadata
    };
  }

  /// Returns the file size formatted as a localized string (e.g., '1.5 MB').
  String get fileSizeFormatted {
    return _formatBytes(fileSize);
  }

  /// Internal helper for formatting byte counts.
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Represents the user's storage limits and current consumption on NeoSync.
class NeoSyncQuota {
  /// Total bytes currently used by the user's cloud saves.
  final int usedQuota;

  /// Total bytes allowed for the user's current subscription plan.
  final int totalQuota;

  NeoSyncQuota({required this.usedQuota, required this.totalQuota});

  /// Creates a [NeoSyncQuota] from a JSON-compatible map.
  factory NeoSyncQuota.fromJson(Map<String, dynamic> json) {
    return NeoSyncQuota(
      usedQuota: int.tryParse((json['used_quota'] ?? '0').toString()) ?? 0,
      totalQuota: int.tryParse((json['total_quota'] ?? '0').toString()) ?? 0,
    );
  }

  /// Converts the quota information into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {'used_quota': usedQuota, 'total_quota': totalQuota};
  }

  /// Returns the percentage of the quota that has been consumed.
  double get usagePercentage {
    if (totalQuota == 0) return 0.0;
    return (usedQuota / totalQuota) * 100;
  }

  /// Returns formatted used quota string.
  String get usedQuotaFormatted => _formatBytes(usedQuota);

  /// Returns formatted total quota string.
  String get totalQuotaFormatted => _formatBytes(totalQuota);

  /// Returns formatted remaining storage string.
  String get remainingQuotaFormatted {
    final remaining = totalQuota - usedQuota;
    return _formatBytes(remaining > 0 ? remaining : 0);
  }

  /// Internal helper for formatting byte counts.
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Represents a physical save file located on the user's local filesystem.
class LocalSaveFile {
  /// Full absolute path to the local save file.
  final String filePath;

  /// The physical filename.
  final String fileName;

  /// Size of the local file in bytes.
  final int fileSize;

  /// Last modified timestamp from the filesystem.
  final DateTime lastModified;

  /// Name of the game associated with this local save.
  final String gameName;

  /// Whether this local file is currently in sync with the cloud version.
  final bool isSynced;

  /// Path relative to the tracked synchronization root.
  final String relativePath;

  LocalSaveFile({
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required this.lastModified,
    required this.gameName,
    required this.isSynced,
    required this.relativePath,
  });

  /// Returns formatted file size string.
  String get fileSizeFormatted {
    return _formatBytes(fileSize);
  }

  /// Internal helper for formatting byte counts.
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Enumeration of possible synchronization states for individual games.
enum GameSyncStatus {
  /// No local or cloud save data exists for the game.
  noSaveFound,

  /// Save data exists only on the local device.
  localOnly,

  /// Save data exists only on the NeoSync servers.
  cloudOnly,

  /// Local and cloud versions are identical.
  upToDate,

  /// A synchronization operation is currently active.
  syncing,

    // DOLPHIN_ISOLATION_BEGIN: neosync207_pending_status
  /// A save check is waiting for the native engine/import to release its files.
  pending,
    // DOLPHIN_ISOLATION_END: neosync207_pending_status

  /// Cloud synchronization is explicitly disabled for this game.
  disabled,

  /// Synchronization is blocked because the storage quota is full.
  quotaExceeded,

  /// Critical emulator components are missing, preventing path resolution.
  missingEmulator,

  /// The last synchronization attempt failed.
  error,
}

/// Represents the comprehensive synchronization state of a specific game.
class GameSyncState {
  /// Unique identifier of the game.
  final String gameId;

  /// User-friendly name of the game.
  final String gameName;

  /// Current [GameSyncStatus] representing the delta between local and cloud.
  final GameSyncStatus status;

  /// Whether cloud sync is active for this game.
  final bool cloudEnabled;

  /// Local save metadata, if available.
  final LocalSaveFile? localSave;

  /// Cloud save metadata, if available.
  final NeoSyncFile? cloudSave;

  /// Timestamp of the last successful synchronization.
  final DateTime? lastSync;

  /// Optional error message if the last sync attempt failed.
  final String? errorMessage;

  GameSyncState({
    required this.gameId,
    required this.gameName,
    required this.status,
    required this.cloudEnabled,
    this.localSave,
    this.cloudSave,
    this.lastSync,
    this.errorMessage,
  });

  /// Returns a new instance with the specified properties updated.
  GameSyncState copyWith({
    String? gameId,
    String? gameName,
    GameSyncStatus? status,
    bool? cloudEnabled,
    LocalSaveFile? localSave,
    NeoSyncFile? cloudSave,
    DateTime? lastSync,
    String? errorMessage,
  }) {
    return GameSyncState(
      gameId: gameId ?? this.gameId,
      gameName: gameName ?? this.gameName,
      status: status ?? this.status,
      cloudEnabled: cloudEnabled ?? this.cloudEnabled,
      localSave: localSave ?? this.localSave,
      cloudSave: cloudSave ?? this.cloudSave,
      lastSync: lastSync ?? this.lastSync,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  /// Returns a user-friendly display text for the current status.
  String get statusDisplayText {
    switch (status) {
      case GameSyncStatus.noSaveFound:
        return 'No save found';
      case GameSyncStatus.localOnly:
        return 'Local only';
      case GameSyncStatus.cloudOnly:
        return 'Cloud only';
      case GameSyncStatus.upToDate:
        return 'Up to date';
      case GameSyncStatus.syncing:
        return 'Syncing...';
    // DOLPHIN_ISOLATION_BEGIN: neosync207_pending_text
      case GameSyncStatus.pending:
        return 'Waiting for emulator files';
    // DOLPHIN_ISOLATION_END: neosync207_pending_text
      case GameSyncStatus.disabled:
        return 'Disabled';
      case GameSyncStatus.quotaExceeded:
        return 'Quota exceeded';
      case GameSyncStatus.missingEmulator:
        return 'No bin selected';
      case GameSyncStatus.error:
        return 'Error';
    }
  }

  /// Returns the UI color associated with the current status.
  Color get statusColor {
    switch (status) {
      case GameSyncStatus.noSaveFound:
        return Colors.grey;
      case GameSyncStatus.localOnly:
        return Colors.orange;
      case GameSyncStatus.cloudOnly:
        return Colors.blue;
      case GameSyncStatus.upToDate:
        return Colors.green;
      case GameSyncStatus.syncing:
        return Colors.blue;
    // DOLPHIN_ISOLATION_BEGIN: neosync207_pending_color
      case GameSyncStatus.pending:
        return Colors.orange;
    // DOLPHIN_ISOLATION_END: neosync207_pending_color
      case GameSyncStatus.disabled:
        return Colors.grey;
      case GameSyncStatus.quotaExceeded:
        return Colors.red;
      case GameSyncStatus.missingEmulator:
        return Colors.redAccent;
      case GameSyncStatus.error:
        return Colors.red;
    }
  }
}
