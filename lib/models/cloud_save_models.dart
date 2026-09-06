import 'dart:io';
import 'package:flutter/material.dart';
import 'sync_models.dart';

class SaveSyncConfig {
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

  const SaveSyncConfig({
    required this.sync,
    required this.androidSyncFolder,
    required this.windowsSyncFolder,
    required this.linuxSyncFolder,
    required this.macosSyncFolder,
    required this.iosSyncFolder,
  });

  /// Creates a [SaveSyncConfig] from a JSON-compatible map.
  factory SaveSyncConfig.fromJson(Map<String, dynamic> json) {
    return SaveSyncConfig(
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
  static const SaveSyncConfig empty = SaveSyncConfig(
    sync: true,
    androidSyncFolder: [],
    windowsSyncFolder: [],
    linuxSyncFolder: [],
    macosSyncFolder: [],
    iosSyncFolder: [],
  );
}

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

  /// Save data exists only on the connected cloud folder.
  cloudOnly,

  /// Local and cloud versions are identical.
  upToDate,

  /// A synchronization operation is currently active.
  syncing,

  /// A save check is waiting for the native engine/import to release its files.
  pending,

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
  final SyncFile? cloudSave;

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
    SyncFile? cloudSave,
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
      case GameSyncStatus.pending:
        return 'Waiting for emulator files';
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
      case GameSyncStatus.pending:
        return Colors.orange;
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
