import 'dart:convert';
import 'dart:io';
// DOLPHIN_ISOLATION_BEGIN: neosync_legacy_cleanup_import
import 'neo_sync_cloud_cleanup.dart';
// DOLPHIN_ISOLATION_END: neosync_legacy_cleanup_import

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/app_config.dart';

// DOLPHIN_ISOLATION_BEGIN: neosync_legacy_cleanup_contract
/// Compatibility bridge for historical NeoSync v1 storage. Save migration does
/// not delete originals. The saves-only cleanup removes proven non-saves only.
/// Files are exposed to the v2
// DOLPHIN_ISOLATION_END: neosync_legacy_cleanup_contract
/// provider with an ID prefixed by `v1:` so callers can route download/delete
/// requests to the legacy service without changing the shared file model.
class LegacyNeoSyncService {
  static const String _tokenKey = 'auth_token';
  static const String _idPrefix = 'v1:';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final LoggerService _log = LoggerService.instance;

  static bool isLegacyId(String id) => id.startsWith(_idPrefix);

  static String rawId(String id) =>
      isLegacyId(id) ? id.substring(_idPrefix.length) : id;

  Future<String?> _getToken() async {
    if (Platform.isMacOS) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_tokenKey);
    }
    return _storage.read(key: _tokenKey);
  }

  Future<Map<String, String>> _headers() async {
    final token = await _getToken();
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  Future<Map<String, dynamic>> getFiles() async {
// DOLPHIN_ISOLATION_BEGIN: neosync_legacy_inventory_token
    final token = await _getToken();
    return _getFilesWithHeaders({'Authorization': 'Bearer $token', 'Content-Type': 'application/json'});
  }

  Future<Map<String, dynamic>> _getFilesWithHeaders(Map<String, String> headers) async {
// DOLPHIN_ISOLATION_END: neosync_legacy_inventory_token
    try {
      final response = await http.get(
        Uri.parse('${AppConfig.legacyNeoSyncBaseUrl}/api/v1/files'),
        // DOLPHIN_ISOLATION_BEGIN: neosync_legacy_bound_listing
headers: headers,
// DOLPHIN_ISOLATION_END: neosync_legacy_bound_listing
      );
      if (response.statusCode != 200) {
        _log.w('NeoSync v1 file listing failed: HTTP ${response.statusCode}');
        return {
          'success': false,
          'message': 'Legacy NeoSync HTTP ${response.statusCode}',
          'status_code': response.statusCode,
        };
      }

      final data = jsonDecode(response.body);
      // DOLPHIN_ISOLATION_BEGIN: neosync_legacy_inventory_validation
      if (data is! Map || data['files'] is! List ||
          (data['files'] as List).any((item) => item is! Map)) {
        throw const FormatException('Invalid legacy NeoSync inventory');
      }
      for (final metadata in [data, if (data['pagination'] is Map) data['pagination'] as Map,
          if (data['meta'] is Map) data['meta'] as Map]) {
        final total = int.tryParse('${metadata['total'] ?? metadata['total_count'] ?? ''}');
        final more = metadata['has_more'];
        if (more == true || more == 1 || more == 'true' ||
            (metadata['next'] != null && metadata['next'] != false && metadata['next'] != '') ||
            (metadata['next_cursor'] != null && metadata['next_cursor'] != '') ||
            (metadata['next_page'] != null && metadata['next_page'] != false) ||
            (total != null && total > (data['files'] as List).length)) {
          throw StateError('Legacy NeoSync inventory is incomplete; no cleanup performed');
        }
      }
      // DOLPHIN_ISOLATION_END: neosync_legacy_inventory_validation
      final files =
          (data['files'] as List?)?.whereType<Map>().map((raw) {
            final json = Map<String, dynamic>.from(raw);
            final parsed = NeoSyncFile.fromJson(json);
            // DOLPHIN_ISOLATION_BEGIN: neosync_legacy_valid_id
            if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(parsed.id)) {
              throw const FormatException('Invalid legacy NeoSync file ID');
            }
            // DOLPHIN_ISOLATION_END: neosync_legacy_valid_id
            return NeoSyncFile(
              id: '$_idPrefix${parsed.id}',
              fileName: parsed.fileName,
              filePath: parsed.filePath,
              fileSize: parsed.fileSize,
              gameName: parsed.gameName,
              uploadedAt: parsed.uploadedAt,
              fileModifiedAt: parsed.fileModifiedAt,
              fileModifiedAtTimestamp: parsed.fileModifiedAtTimestamp,
              userId: parsed.userId,
              checksum: parsed.checksum,
            );
          }).toList() ??
          const <NeoSyncFile>[];
      return {'success': true, 'files': files};
    } catch (e) {
      _log.w('NeoSync v1 file listing unavailable: $e');
      return {'success': false, 'message': e.toString()};
    }
  }

// DOLPHIN_ISOLATION_BEGIN: neosync_legacy_requested_cleanup
  Future<Map<String, dynamic>> auditAndPurge({
    required Future<List<NeoSyncFile>> Function(List<NeoSyncFile>) resolveOrigins,
  }) async {
    try {
      final token = await _getToken();
      if (token == null || token.isEmpty) throw StateError('Not authenticated');
      final headers = {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
      final listing = await _getFilesWithHeaders(headers);
      if (listing['success'] != true) return listing;
      final result = await NeoSyncCloudCleanup.run(
        inventory: await resolveOrigins(listing['files'] as List<NeoSyncFile>),
        isCurrentAccount: () async => await _getToken() == token,
        delete: (file) async {
          final response = await http.delete(
            Uri.parse('${AppConfig.legacyNeoSyncBaseUrl}/api/v1/files/${Uri.encodeComponent(rawId(file.id))}'),
            headers: headers).timeout(const Duration(seconds: 30));
          _log.i('NeoSync v1 non-save purge: ${file.id} ${file.sourceSavePath} HTTP ${response.statusCode}');
          return response.statusCode == 200 || response.statusCode == 204;
        },
      );
      return {'success': true, 'files': result.remaining,
        'deleted': result.deletedIds.length, 'failed': result.failedIds.length,
        'unresolved': result.unresolved};
    } catch (error) {
      return {'success': false, 'message': 'Legacy cleanup stopped: $error'};
    }
  }

// DOLPHIN_ISOLATION_END: neosync_legacy_requested_cleanup

  Future<Map<String, dynamic>> downloadFile(String id) async {
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.legacyNeoSyncBaseUrl}/api/v1/download'),
        headers: await _headers(),
        body: jsonEncode({'file_id': rawId(id)}),
      );
      if (response.statusCode != 200) {
        return {
          'success': false,
          'message': 'Legacy NeoSync HTTP ${response.statusCode}',
          'status_code': response.statusCode,
        };
      }

      final data = jsonDecode(response.body);
      final downloadUrl = data['download_url']?.toString();
      if (downloadUrl == null || downloadUrl.isEmpty) {
        return {'success': false, 'message': 'No legacy download URL'};
      }

      final fileResponse = await http.get(Uri.parse(downloadUrl));
      if (fileResponse.statusCode != 200) {
        return {
          'success': false,
          'message': 'Legacy file HTTP ${fileResponse.statusCode}',
        };
      }
      return {'success': true, 'data': fileResponse.bodyBytes};
    } catch (e) {
      _log.w('NeoSync v1 download unavailable: $e');
      return {'success': false, 'message': e.toString()};
    }
  }

  /// Explicit deletion support for the UI. Automatic migration never calls it.
  Future<Map<String, dynamic>> deleteFile(String id) async {
    try {
      final response = await http.delete(
        Uri.parse(
          '${AppConfig.legacyNeoSyncBaseUrl}/api/v1/files/${rawId(id)}',
        ),
        headers: await _headers(),
      );
      return {
        'success': response.statusCode == 200 || response.statusCode == 204,
        if (response.statusCode != 200 && response.statusCode != 204)
          'message': 'Legacy NeoSync HTTP ${response.statusCode}',
      };
    } catch (e) {
      _log.w('NeoSync v1 delete unavailable: $e');
      return {'success': false, 'message': e.toString()};
    }
  }
}
