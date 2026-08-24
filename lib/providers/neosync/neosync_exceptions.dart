part of '../neo_sync_provider.dart';

/// Exception for when the quota is exceeded
class QuotaExceededException implements Exception {
  final String message;
  final int attemptCount;

  QuotaExceededException(this.message, this.attemptCount);

  @override
  String toString() =>
      'QuotaExceededException: $message (attempt $attemptCount)';
}

/// Exception for when a file is not found
class FileNotFoundException implements Exception {
  final String message;

  FileNotFoundException(this.message);

  @override
  String toString() => 'FileNotFoundException: $message';
}

/// Exception for when conflicts are detected during synchronization
class ConflictDetectedException implements Exception {
  final List<ConflictPendingResolution> conflicts;

  ConflictDetectedException(this.conflicts);

  @override
  String toString() =>
      'ConflictDetectedException: ${conflicts.length} conflicts detected';
}

/// Class to handle pending conflicts
class ConflictPendingResolution {
  final NeoSyncFile cloudFile;
  final File localFile;
  final String description;

  ConflictPendingResolution({
    required this.cloudFile,
    required this.localFile,
    required this.description,
  });
}
