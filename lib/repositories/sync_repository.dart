import '../data/datasources/sqlite_service.dart';

/// Repository for NeoSync cloud save synchronization state.
class SyncRepository {
  /// Persists local synchronization state for a file.
  static Future<void> saveSyncState(
    String filePath,
    int localModifiedAt,
    int cloudUpdatedAt,
    int fileSize, {
    String? fileHash,
  }) => SqliteService.saveSyncState(
    filePath,
    localModifiedAt,
    cloudUpdatedAt,
    fileSize,
    fileHash: fileHash,
  );

  /// Retrieves the recorded synchronization state for a specific file path.
  static Future<Map<String, dynamic>?> getSyncState(String filePath) =>
      SqliteService.getSyncState(filePath);
}
