import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as path;

enum RetroArchSyncOutcome { synced, unavailable, timedOut, empty, invalid }

/// The URL open result is only transport acceptance. Completion requires a
/// validated library callback. One request at a time, bounded waiting, and
/// no retry that could race an uncorrelated callback from RetroArch.
class RetroArchSyncController {
  RetroArchSyncController({this.timeout = const Duration(seconds: 15)});

  final Duration timeout;
  Completer<RetroArchSyncOutcome>? _pending;
  Timer? _timer;
  RetroArchSyncOutcome? lastOutcome;
  Object? lastTransportError;
  bool get isPending => _pending != null;

  Future<RetroArchSyncOutcome> request(Future<bool> Function() send) {
    final existing = _pending;
    if (existing != null) return existing.future;
    final pending = Completer<RetroArchSyncOutcome>();
    _pending = pending;
    lastOutcome = null;
    lastTransportError = null;
    _timer = Timer(timeout, () => complete(RetroArchSyncOutcome.timedOut));
    Future<bool>.sync(send).then(
      (opened) {
        if (identical(_pending, pending) && !opened) {
          complete(RetroArchSyncOutcome.unavailable);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_pending, pending)) {
          lastTransportError = error;
          complete(RetroArchSyncOutcome.unavailable);
        }
      },
    );
    return pending.future;
  }

  void complete(RetroArchSyncOutcome outcome) {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    _timer?.cancel();
    _timer = null;
    lastOutcome = outcome;
    pending.complete(outcome);
  }
}

/// Matches the official RetroArchPlaylistManager export. Reject a malformed
/// payload atomically rather than replacing a usable cache with partial data.
abstract final class RetroArchLibraryProtocol {
  static List<Map<String, dynamic>> decode(String payload) {
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(payload))),
    );
    if (decoded is! List) {
      throw const FormatException('RetroArch payload is not a list');
    }
    return decoded.map((entry) {
      if (entry is! Map) {
        throw const FormatException('RetroArch entry is not an object');
      }
      final map = Map<String, dynamic>.from(entry);
      final filename = map['filename'] ?? map['titleId'];
      if (filename is! String || filename.trim().isEmpty) {
        throw const FormatException('RetroArch entry has no filename');
      }
      return map;
    }).toList();
  }

  static Map<String, Map<String, dynamic>> index(
    List<Map<String, dynamic>> entries,
  ) {
    final indexed = <String, Map<String, dynamic>>{};
    for (var index = 0; index < entries.length; index++) {
      final map = entries[index];
      // Preserve every export record. Filename aliases below are convenience
      // lookups, never identities: two source paths can share a launch name.
      indexed['retroarch-export-record:$index'] = map;
      final filename = (map['filename'] ?? map['titleId']) as String;
      indexed[filename] = map;
      indexed[path.basename(filename)] = map;
      final system = map['system'];
      if (system is String && system.isNotEmpty) {
        indexed[Uri(
              scheme: 'retroarch-library',
              host: 'game',
              pathSegments: [system, filename],
            ).toString()] =
            map;
      }
      final hashIndex = filename.indexOf('#');
      if (hashIndex > 0) {
        indexed[path.basename(filename.substring(0, hashIndex))] = map;
      }
      indexed.putIfAbsent(path.basenameWithoutExtension(filename), () => map);
    }
    return indexed;
  }
}
