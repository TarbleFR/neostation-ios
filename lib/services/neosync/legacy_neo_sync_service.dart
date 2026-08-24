import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/app_config.dart';

/// Read-only compatibility bridge for the historical NeoSync v1 storage.
///
/// The v1 files are never removed automatically. They are exposed to the v2
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
    try {
      final response = await http.get(
        Uri.parse('${AppConfig.legacyNeoSyncBaseUrl}/api/v1/files'),
        headers: await _headers(),
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
      final files =
          (data['files'] as List?)?.whereType<Map>().map((raw) {
            final json = Map<String, dynamic>.from(raw);
            final parsed = NeoSyncFile.fromJson(json);
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
