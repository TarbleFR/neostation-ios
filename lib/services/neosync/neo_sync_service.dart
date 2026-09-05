import 'dart:convert';
import 'dart:io';
// DOLPHIN_ISOLATION_BEGIN: neosync_global_save_policy_imports
import 'neo_sync_save_policy.dart';
import 'neo_sync_cloud_cleanup.dart';
// DOLPHIN_ISOLATION_END: neosync_global_save_policy_imports

import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/utils/app_config.dart';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:neostation/services/logger_service.dart';

import '../../repositories/sync_repository.dart';

/// Service responsible for communicating with the NeoSync cloud synchronization API.
///
/// Handles file uploads, downloads, quota management, and synchronization
/// conflict resolution for game save states and configurations.
class NeoSyncService extends ChangeNotifier {
  static const String _tokenKey = 'auth_token';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final _log = LoggerService.instance;

  bool _isLoading = false;
  String? _lastError;

  bool get isLoading => _isLoading;
  String? get lastError => _lastError;

  void _safeNotifyListeners() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notifyListeners();
    });
  }

  /// Computes the MD5 hash of the given byte list.
  String _calculateFileHash(List<int> bytes) {
    return md5.convert(bytes).toString();
  }

  /// Computes the MD5 hash of the given byte list (public wrapper).
  String calculateFileHash(List<int> bytes) {
    return _calculateFileHash(bytes);
  }

  /// Queries the API to check if a specific file exists on the server and
  /// determines if a synchronization is required.
  ///
  /// Considers file hash, size, and modification timestamps to detect changes.
  Future<Map<String, dynamic>> checkFileExists(
    String filename,
    String fileHash,
    int fileSize, {
    DateTime? localModifiedAt,
  }) async {
    try {
      final headers = await _getHeaders();
      final baseUrl = AppConfig.neoSyncBaseUrl;
      final uri = Uri.parse('$baseUrl/api/v2/files/check');

      final requestBody = {
        'filename': filename,
        'hash': fileHash,
        'size': fileSize,
      };

      if (localModifiedAt != null) {
        final timestampMillis = localModifiedAt.millisecondsSinceEpoch;
        requestBody['local_modified_at_timestamp'] = timestampMillis;
      }

      final response = await http.post(
        uri,
        headers: headers,
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'exists': data['exists'] ?? false,
          'needs_sync': data['needs_sync'] ?? true,
          'remote_newer': data['remote_newer'] ?? false,
          'db_modified_at_timestamp': data['db_modified_at_timestamp'],
          'metadata': data['metadata'],
        };
      } else {
        _log.e('Check request failed with status: ${response.statusCode}');
        return {'exists': false, 'needs_sync': true, 'remote_newer': false};
      }
    } catch (e) {
      _log.e('Check request error: $e');
      return {'exists': false, 'needs_sync': true, 'remote_newer': false};
    }
  }

  /// Synchronizes a local file with the cloud.
  ///
  /// Performs a pre-flight check to avoid redundant uploads. Updates the local
  /// sync state in the database upon success.
  Future<Map<String, dynamic>> syncFile(
    File file,
    String gameName, {
    String? customFilename,
    String? systemId,
    String? emulatorId,
    String? gameHash,
    bool? isState,
    String? scope,
    bool contentHashOnly = false,
  }) async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
// DOLPHIN_ISOLATION_BEGIN: neosync_syncFile_save_policy
      final cloudKey = customFilename ?? file.path;
      if (!NeoSyncSavePolicy.allowsUpload(file.path, cloudKey)) {
        return {'success': false, 'excluded': true,
          'message': 'NeoSync accepts only internal saves and savestates: $cloudKey'};
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
        return {'success': false, 'excluded': true, 'message': 'NeoSync refuses linked save files'};
      }
// DOLPHIN_ISOLATION_END: neosync_syncFile_save_policy
      final fileBytes = await file.readAsBytes();
      final fileHash = _calculateFileHash(fileBytes);
      final filename = customFilename ?? file.path;

      final fileStat = await file.stat();
      final localModifiedAt = fileStat.modified;

      final checkResult = await checkFileExists(
        filename,
        fileHash,
        fileBytes.length,
        localModifiedAt: contentHashOnly ? null : localModifiedAt,
      );

      if (!checkResult['needs_sync']) {
        int cloudTime = localModifiedAt.millisecondsSinceEpoch;
        if (checkResult['db_modified_at_timestamp'] != null) {
          final ts = checkResult['db_modified_at_timestamp'];
          if (ts is int) cloudTime = ts;
          if (ts is String) cloudTime = int.tryParse(ts) ?? cloudTime;
        }
        await SyncRepository.saveSyncState(
          file.path,
          localModifiedAt.millisecondsSinceEpoch,
          cloudTime,
          fileBytes.length,
          fileHash: fileHash,
        );
        return {
          'success': true,
          'skipped': true,
          'message': 'File already in sync',
        };
      }

      if (checkResult['remote_newer'] && !contentHashOnly) {
        return {
          'success': true,
          'skipped': true,
          'message': 'Remote file is newer',
        };
      }

      final token = await _getToken();
      if (token == null) {
        throw Exception('Not authenticated');
      }

      final baseUrl = AppConfig.neoSyncBaseUrl;
      final uri = Uri.parse('$baseUrl/api/v2/upload');

      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer $token';

      request.files.add(
        http.MultipartFile.fromBytes('file', fileBytes, filename: filename),
      );

      final fileModifiedAtTimestamp = contentHashOnly
          ? DateTime.now().millisecondsSinceEpoch
          : localModifiedAt.millisecondsSinceEpoch;

      request.fields['file_name'] = filename;
      request.fields['game_name'] = gameName;
      request.fields['file_hash'] = fileHash;
      request.fields['file_size'] = fileBytes.length.toString();
      request.fields['file_modified_at_timestamp'] = fileModifiedAtTimestamp
          .toString();
      if (systemId != null && systemId.isNotEmpty) {
        request.fields['system_id'] = systemId;
      }
      if (emulatorId != null && emulatorId.isNotEmpty) {
        request.fields['emulator_id'] = emulatorId;
      }
      if (gameHash != null && gameHash.isNotEmpty) {
        request.fields['game_hash'] = gameHash;
      }
      if (isState != null) {
        request.fields['is_state'] = isState.toString();
      }
      if (scope != null && scope.isNotEmpty) {
        request.fields['scope'] = scope;
      }

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      Map<String, dynamic> data = <String, dynamic>{};
      try {
        final decoded = jsonDecode(responseBody);
        if (decoded is Map<String, dynamic>) data = decoded;
      } catch (_) {
        // Some proxies return plain text/HTML for transport errors such as 413.
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        int cloudTime = fileModifiedAtTimestamp;
        if (data['file_modified_at_timestamp'] != null) {
          final ts = data['file_modified_at_timestamp'];
          if (ts is int) cloudTime = ts;
          if (ts is String) cloudTime = int.tryParse(ts) ?? cloudTime;
        }
        await SyncRepository.saveSyncState(
          file.path,
          localModifiedAt.millisecondsSinceEpoch,
          cloudTime,
          fileBytes.length,
          fileHash: fileHash,
        );
        return {'success': true, 'data': data};
      } else {
        final body = responseBody.trim();
        final bodyPreview = body.length > 240
            ? '${body.substring(0, 240)}…'
            : body;
        final error =
            data['error'] ??
            data['message'] ??
            (bodyPreview.isNotEmpty
                ? 'HTTP ${response.statusCode}: $bodyPreview'
                : 'Upload failed (HTTP ${response.statusCode})');
        _log.e('Upload failed: $error');
        return {'success': false, 'message': error};
      }
    } catch (e) {
      final error = 'Network error: $e';
      _log.e('Sync error: $error');
      _lastError = error;
      return {'success': false, 'message': error};
    } finally {
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  /// Retrieves the JWT authentication token from secure storage.
  Future<String?> _getToken() async {
    if (Platform.isMacOS) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_tokenKey);
    }
    return await _storage.read(key: _tokenKey);
  }

  /// Generates the standard HTTP headers required for authenticated API requests.
  Future<Map<String, String>> _getHeaders() async {
    final token = await _getToken();
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  /// Forces an upload of a specific file to the cloud.
  Future<Map<String, dynamic>> uploadFile(
    File file,
    String gameName, {
    String? customFilename,
  }) async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
// DOLPHIN_ISOLATION_BEGIN: neosync_uploadFile_save_policy
      final cloudKey = customFilename ?? file.path;
      if (!NeoSyncSavePolicy.allowsUpload(file.path, cloudKey)) {
        return {'success': false, 'excluded': true,
          'message': 'NeoSync accepts only internal saves and savestates: $cloudKey'};
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
        return {'success': false, 'excluded': true, 'message': 'NeoSync refuses linked save files'};
      }
// DOLPHIN_ISOLATION_END: neosync_uploadFile_save_policy
      final token = await _getToken();
      if (token == null) {
        throw Exception('Not authenticated');
      }

      final baseUrl = AppConfig.neoSyncBaseUrl;
      final uri = Uri.parse('$baseUrl/api/v2/upload');

      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer $token';

      final fileBytes = await file.readAsBytes();
      final filename =
          customFilename ?? file.path.split(Platform.pathSeparator).last;
      request.files.add(
        http.MultipartFile.fromBytes('file', fileBytes, filename: filename),
      );

      request.fields['file_name'] = filename;
      request.fields['game_name'] = gameName;

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      final data = jsonDecode(responseBody);

      if (response.statusCode == 200 || response.statusCode == 201) {
        return {'success': true, 'data': data};
      } else {
        final error = data['error'] ?? 'Upload failed';
        _log.e('Upload failed: $error');
        return {'success': false, 'message': error};
      }
    } catch (e) {
      final error = 'Network error: $e';
      _log.e('Upload error: $error');
      _lastError = error;
      return {'success': false, 'message': error};
    } finally {
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  // DOLPHIN_ISOLATION_BEGIN: dolphin_complete_cloud_listing
  /// Neither synchronization nor cleanup may mistake an incomplete page for
  /// the full account inventory. Both use this bounded pagination routine.
  Future<Map<String, dynamic>> getDolphinSaveFiles() async =>
      _getCompleteFiles(await _getHeaders());

  Future<Map<String, dynamic>> _getCompleteFiles(Map<String, String> headers) async {
    try {
      final files = <NeoSyncFile>[];
      final seen = <String>{};
      var offset = 0;
      for (var page = 0; page < 100; page++) {
        final uri = Uri.parse('${AppConfig.neoSyncBaseUrl}/api/v2/files')
            .replace(queryParameters: {'limit': '200', 'offset': '$offset'});
        final response = await http.get(uri, headers: headers)
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          throw StateError('NeoSync listing HTTP ${response.statusCode}');
        }
        final data = jsonDecode(response.body);
        if (data is! Map || data['files'] is! List) {
          throw const FormatException('Invalid NeoSync file page');
        }
        final batch = (data['files'] as List)
            .map((item) => NeoSyncFile.fromJson(Map<String, dynamic>.from(item as Map))).toList();
        for (final file in batch) {
          if (file.id.isEmpty || !seen.add(file.id)) {
            throw StateError('NeoSync pagination repeated a file; refusing an incomplete list');
          }
          files.add(file);
        }
        if (batch.length < 200) return {'success': true, 'files': files};
        offset += batch.length;
      }
      throw StateError('NeoSync listing limit reached; refusing an incomplete list');
    } catch (error) {
      _log.e('[NeoSync][DolphiniOS][list.failed] $error');
      return {'success': false, 'message': '$error'};
    }
  }
  // DOLPHIN_ISOLATION_END: dolphin_complete_cloud_listing

  /// Fetches the metadata list of all files currently stored in the user's cloud account.
// DOLPHIN_ISOLATION_BEGIN: neosync_complete_inventory
  Future<Map<String, dynamic>> getFiles() async => getDolphinSaveFiles();

  Future<Map<String, dynamic>> auditAndPurge({
    required Future<List<NeoSyncFile>> Function(List<NeoSyncFile>) resolveOrigins,
  }) async {
    try {
      final token = await _getToken();
      if (token == null || token.isEmpty) throw StateError('Not authenticated');
      final headers = {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
      final listing = await _getCompleteFiles(headers);
      if (listing['success'] != true) return listing;
      final inventory = await resolveOrigins(listing['files'] as List<NeoSyncFile>);
      final result = await NeoSyncCloudCleanup.run(
        inventory: inventory,
        isCurrentAccount: () async => await _getToken() == token,
        delete: (file) async {
          final response = await http.delete(
            Uri.parse('${AppConfig.neoSyncBaseUrl}/api/v2/files/${Uri.encodeComponent(file.id)}'),
            headers: headers).timeout(const Duration(seconds: 30));
          final success = response.statusCode == 200 || response.statusCode == 204;
          _log.i('NeoSync non-save purge: ${file.id} ${file.sourceSavePath} HTTP ${response.statusCode}');
          return success;
        },
      );
      return {'success': true, 'files': result.remaining,
        'deleted': result.deletedIds.length, 'failed': result.failedIds.length,
        'unresolved': result.unresolved};
    } catch (error) {
      return {'success': false, 'message': 'NeoSync cleanup stopped: $error'};
    }
  }

// DOLPHIN_ISOLATION_END: neosync_complete_inventory
  /// Deletes a specific file from the cloud storage by its unique identifier.
  Future<Map<String, dynamic>> deleteFile(String fileId) async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final headers = await _getHeaders();
      final baseUrl = AppConfig.neoSyncBaseUrl;
      final uri = Uri.parse('$baseUrl/api/v2/files/$fileId');

      final response = await http.delete(uri, headers: headers);

      if (response.statusCode == 200 || response.statusCode == 204) {
        return {'success': true};
      } else {
        final data = jsonDecode(response.body);
        final error = data['error'] ?? 'Failed to delete file';
        _log.e('Delete failed: $error');
        return {'success': false, 'message': error};
      }
    } catch (e) {
      final error = 'Network error: $e';
      _log.e('Delete error: $error');
      _lastError = error;
      return {'success': false, 'message': error};
    } finally {
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  /// Fetches the user's current cloud storage quota and usage details.
  Future<Map<String, dynamic>> getQuota() async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final headers = await _getHeaders();
      final baseUrl = AppConfig.neoSyncBaseUrl;
      final uri = Uri.parse('$baseUrl/api/v2/quota');

      final response = await http.get(uri, headers: headers);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final quota = NeoSyncQuota.fromJson(data);

        return {'success': true, 'quota': quota};
      } else {
        final data = jsonDecode(response.body);
        final error = data['error'] ?? 'Failed to fetch quota';
        _log.e('Quota fetch failed: $error');
        return {'success': false, 'message': error};
      }
    } catch (e) {
      final error = 'Network error: $e';
      _log.e('Quota fetch error: $error');
      _lastError = error;
      return {'success': false, 'message': error};
    } finally {
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  /// Downloads a file from cloud storage.
  ///
  /// The process involves requesting a signed URL from the API and then
  /// performing a GET request to that URL to retrieve the raw bytes.
  Future<Map<String, dynamic>> downloadFile(String fileId) async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final headers = await _getHeaders();
      final baseUrl = AppConfig.neoSyncBaseUrl;
      final uri = Uri.parse('$baseUrl/api/v2/download');

      final requestBody = {'file_id': fileId};

      final response = await http.post(
        uri,
        headers: headers,
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final downloadUrl = data['download_url'];

        if (downloadUrl == null) {
          throw Exception('No download URL in response');
        }

        final fileResponse = await http.get(Uri.parse(downloadUrl));

        if (fileResponse.statusCode == 200) {
          return {'success': true, 'data': fileResponse.bodyBytes};
        } else {
          throw Exception(
            'Failed to download from signed URL: ${fileResponse.statusCode}',
          );
        }
      } else {
        String error;
        if (response.statusCode == 404) {
          error = 'File not found (404)';
          _log.e('File not found: $uri');
        } else if (response.statusCode == 401) {
          error = 'Unauthorized (401) - Authentication required';
          _log.e('Unauthorized access to: $uri');
        } else if (response.statusCode == 403) {
          error = 'Forbidden (403) - Access denied';
          _log.e('Access forbidden to: $uri');
        } else if (response.statusCode == 500) {
          error = 'Server error (500) - Internal server error';
          _log.e('Server error for: $uri');
        } else {
          try {
            final data = jsonDecode(response.body);
            error =
                data['error'] ??
                'HTTP ${response.statusCode}: ${response.reasonPhrase}';
          } catch (jsonError) {
            error =
                'HTTP ${response.statusCode}: ${response.body.length > 100 ? '${response.body.substring(0, 100)}...' : response.body}';
          }
          _log.e('Download failed (${response.statusCode}): $error');
        }

        return {
          'success': false,
          'message': error,
          'status_code': response.statusCode,
        };
      }
    } catch (e) {
      final error = 'Network error: $e';
      _log.e('Download error: $error');
      _lastError = error;
      return {'success': false, 'message': error};
    } finally {
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  /// Clears the last recorded error from the service state.
  void clearError() {
    _lastError = null;
    _safeNotifyListeners();
  }
}
