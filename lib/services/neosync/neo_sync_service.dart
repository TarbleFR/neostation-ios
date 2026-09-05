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
  // DOLPHIN_ISOLATION_BEGIN: neosync_checked_transfer
  Future<Map<String, dynamic>> checkFileExists(
    String filename,
    String fileHash,
    int fileSize, {
    DateTime? localModifiedAt,
    String? accountToken,
  }) async {
    try {
      final headers = accountToken == null ? await _getHeaders() : {
        'Authorization': 'Bearer $accountToken', 'Content-Type': 'application/json',
      };
      final body = <String, Object>{'filename': filename, 'hash': fileHash, 'size': fileSize};
      if (localModifiedAt != null) body['local_modified_at_timestamp'] = localModifiedAt.millisecondsSinceEpoch;
      final response = await http.post(
        Uri.parse('${AppConfig.neoSyncBaseUrl}/api/v2/files/check'),
        headers: headers, body: jsonEncode(body),
      ).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw StateError('NeoSync file check HTTP ${response.statusCode}');
      final data = jsonDecode(response.body);
      if (data is! Map || data['exists'] is! bool || data['needs_sync'] is! bool ||
          (data['remote_newer'] != null && data['remote_newer'] is! bool)) {
        throw const FormatException('Invalid NeoSync file check');
      }
      return {
        'success': true,
        'exists': data['exists'], 'needs_sync': data['needs_sync'],
        'remote_newer': data['remote_newer'] ?? false,
        'db_modified_at_timestamp': data['db_modified_at_timestamp'],
        'metadata': data['metadata'],
      };
    } catch (error) {
      _log.e('NeoSync file check failed: $error');
      return {'success': false, 'exists': false, 'needs_sync': true,
        'remote_newer': false, 'message': '$error'};
    }
  }

  Future<bool> _confirmUploadedContent(Map<String, dynamic> data,
      String filename, String hash, int size, String token) async {
    if (await _getToken() != token) return false;
    for (final metadata in [data, if (data['file'] is Map) data['file'] as Map,
        if (data['data'] is Map) data['data'] as Map]) {
      final serverHash = metadata['file_hash'] ?? metadata['checksum'];
      if (serverHash is String && RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(serverHash)) {
        return serverHash.toLowerCase() == hash;
      }
    }
    final checked = await checkFileExists(filename, hash, size, accountToken: token);
    return await _getToken() == token && checked['success'] == true &&
        checked['exists'] == true && checked['needs_sync'] == false &&
        checked['remote_newer'] != true;
  }
  // DOLPHIN_ISOLATION_END: neosync_checked_transfer

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
    // DOLPHIN_ISOLATION_BEGIN: neosync_source_context
    NeoSyncSaveSource? source,
    // DOLPHIN_ISOLATION_END: neosync_source_context
  }) async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
// DOLPHIN_ISOLATION_BEGIN: neosync_syncFile_save_policy
      final cloudKey = customFilename ?? file.path;
      if (!NeoSyncSavePolicy.allowsUpload(file.path, cloudKey, source: source)) {
        return {'success': false, 'excluded': true,
          'message': 'NeoSync accepts only internal saves and savestates: $cloudKey'};
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
        return {'success': false, 'excluded': true, 'message': 'NeoSync refuses linked save files'};
      }
      final token = await _getToken();
      if (token == null || token.isEmpty) throw StateError('Not authenticated');
// DOLPHIN_ISOLATION_END: neosync_syncFile_save_policy
// DOLPHIN_ISOLATION_BEGIN: neosync_stable_snapshot
      final before = await file.stat();
      final fileBytes = await file.readAsBytes();
      final after = await file.stat();
      if (before.size != after.size || before.modified != after.modified || fileBytes.length != after.size) {
        return {'success': false, 'deferred': true, 'message': 'Save changed while preparing upload; retry required'};
      }
// DOLPHIN_ISOLATION_END: neosync_stable_snapshot
      final fileHash = _calculateFileHash(fileBytes);
      final filename = customFilename ?? file.path;

      // DOLPHIN_ISOLATION_BEGIN: neosync_snapshot_time
      final localModifiedAt = after.modified;
      // DOLPHIN_ISOLATION_END: neosync_snapshot_time

      final checkResult = await checkFileExists(
        filename,
        fileHash,
        fileBytes.length,
        localModifiedAt: contentHashOnly ? null : localModifiedAt,
        // DOLPHIN_ISOLATION_BEGIN: neosync_check_account
        accountToken: token,
        // DOLPHIN_ISOLATION_END: neosync_check_account
      );
// DOLPHIN_ISOLATION_BEGIN: neosync_failed_check_blocks_upload
      if (checkResult['success'] != true) {
        _lastError = checkResult['message']?.toString() ?? 'NeoSync file check failed';
        return {'success': false, 'message': _lastError};
      }
      if (await _getToken() != token) throw StateError('NeoSync account changed');
      if (checkResult['exists'] == true && checkResult['needs_sync'] == false &&
          checkResult['remote_newer'] != true) {
// DOLPHIN_ISOLATION_END: neosync_failed_check_blocks_upload
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
          // DOLPHIN_ISOLATION_BEGIN: neosync_confirmed_skip
          'synced': true,
          // DOLPHIN_ISOLATION_END: neosync_confirmed_skip
          'message': 'File already in sync',
        };
      }

      if (checkResult['remote_newer'] && !contentHashOnly) {
        return {
          'success': true,
          'skipped': true,
          // DOLPHIN_ISOLATION_BEGIN: neosync_deferred_download
          'synced': false,
          'pending_download': true,
          // DOLPHIN_ISOLATION_END: neosync_deferred_download
          'message': 'Remote file is newer',
        };
      }

      // DOLPHIN_ISOLATION_BEGIN: neosync_same_upload_account
      if (await _getToken() != token) throw StateError('NeoSync account changed');
      // DOLPHIN_ISOLATION_END: neosync_same_upload_account

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

      // DOLPHIN_ISOLATION_BEGIN: neosync_upload_timeout
      final response = await request.send().timeout(const Duration(seconds: 60));
      final responseBody = await response.stream.bytesToString().timeout(const Duration(seconds: 60));
      // DOLPHIN_ISOLATION_END: neosync_upload_timeout
      Map<String, dynamic> data = <String, dynamic>{};
      try {
        final decoded = jsonDecode(responseBody);
        if (decoded is Map<String, dynamic>) data = decoded;
      } catch (_) {
        // Some proxies return plain text/HTML for transport errors such as 413.
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        // DOLPHIN_ISOLATION_BEGIN: neosync_confirm_upload
        if (!await _confirmUploadedContent(data, filename, fileHash, fileBytes.length, token)) {
          _lastError = 'Upload received but cloud checksum was not confirmed; retry verification';
          return {'success': false, 'verification_pending': true, 'message': _lastError};
        }
        // DOLPHIN_ISOLATION_END: neosync_confirm_upload
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
    // DOLPHIN_ISOLATION_BEGIN: neosync_forced_source_context
    NeoSyncSaveSource? source,
    // DOLPHIN_ISOLATION_END: neosync_forced_source_context
  }) async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
// DOLPHIN_ISOLATION_BEGIN: neosync_uploadFile_save_policy
      final cloudKey = customFilename ?? file.path;
      if (!NeoSyncSavePolicy.allowsUpload(file.path, cloudKey, source: source)) {
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

      // DOLPHIN_ISOLATION_BEGIN: neosync_forced_snapshot
      final before = await file.stat();
      final fileBytes = await file.readAsBytes();
      final after = await file.stat();
      if (before.size != after.size || before.modified != after.modified || fileBytes.length != after.size) {
        return {'success': false, 'deferred': true, 'message': 'Save changed while preparing upload; retry required'};
      }
      final fileHash = _calculateFileHash(fileBytes);
      if (await _getToken() != token) throw StateError('NeoSync account changed');
      // DOLPHIN_ISOLATION_END: neosync_forced_snapshot
      final filename =
          customFilename ?? file.path.split(Platform.pathSeparator).last;
      request.files.add(
        http.MultipartFile.fromBytes('file', fileBytes, filename: filename),
      );

      request.fields['file_name'] = filename;
      request.fields['game_name'] = gameName;

      // DOLPHIN_ISOLATION_BEGIN: neosync_forced_confirmation
      request.fields['file_hash'] = fileHash;
      request.fields['file_size'] = fileBytes.length.toString();
      final response = await request.send().timeout(const Duration(seconds: 60));
      final responseBody = await response.stream.bytesToString().timeout(const Duration(seconds: 60));
      final data = Map<String, dynamic>.from(jsonDecode(responseBody) as Map);
      if ((response.statusCode == 200 || response.statusCode == 201) &&
          !await _confirmUploadedContent(data, filename, fileHash, fileBytes.length, token)) {
        _lastError = 'Upload received but cloud checksum was not confirmed; retry verification';
        return {'success': false, 'verification_pending': true, 'message': _lastError};
      }
      // DOLPHIN_ISOLATION_END: neosync_forced_confirmation

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
      int? expectedTotal;
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
        // Some deployments cap a page below the requested limit. Explicit
        // pagination metadata takes precedence over a short-page heuristic.
        bool? hasMore;
        int? nextOffset;
        for (final metadata in [data,
          if (data['pagination'] is Map) data['pagination'] as Map,
          if (data['meta'] is Map) data['meta'] as Map]) {
          final totalValue = metadata['total'] ?? metadata['total_count'];
          if (totalValue != null) {
            final total = int.tryParse('$totalValue');
            if (total == null || total < files.length ||
                (expectedTotal != null && expectedTotal != total)) {
              throw StateError('NeoSync inventory changed or has an invalid total');
            }
            expectedTotal = total;
          }
          if (metadata.containsKey('has_more')) {
            final value = metadata['has_more'];
            final more = value == true || value == 1 || value == 'true';
            if (!more && value != false && value != 0 && value != 'false') {
              throw const FormatException('Invalid NeoSync has_more value');
            }
            if (hasMore != null && hasMore != more) {
              throw StateError('Conflicting NeoSync pagination metadata');
            }
            hasMore = more;
          }
          if (metadata['next_offset'] != null) {
            final next = int.tryParse('${metadata['next_offset']}');
            if (next == null || next != offset + batch.length || next <= offset) {
              throw StateError('Invalid NeoSync next offset');
            }
            nextOffset = next;
          }
          if (metadata['next_cursor'] != null && metadata['next_cursor'] != '') {
            throw StateError('Unsupported NeoSync cursor pagination; inventory not verified');
          }
        }
        if (expectedTotal != null) {
          final more = files.length < expectedTotal;
          if (hasMore != null && hasMore != more) {
            throw StateError('NeoSync pagination contradicts its total');
          }
          hasMore = more;
        }
        hasMore ??= nextOffset != null || batch.length >= 200;
        if (!hasMore) return {'success': true, 'files': files};
        if (batch.isEmpty) throw StateError('NeoSync pagination ended before its total');
        offset = nextOffset ?? offset + batch.length;
      }
      throw StateError('NeoSync listing limit reached; refusing an incomplete list');
    } catch (error) {
      _log.e('[NeoSync][DolphiniOS][list.failed] $error');
      return {'success': false, 'phase': 'listing', 'message': '$error'};
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
      return {'success': false, 'phase': 'cleanup', 'message': 'NeoSync cleanup stopped: $error'};
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
