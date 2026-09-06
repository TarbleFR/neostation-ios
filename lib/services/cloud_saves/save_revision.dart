import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'save_snapshot.dart';

/// A revision is immutable. Equal content is deduplicated; independent changes
/// from two devices remain two revisions instead of overwriting one another.
class SaveRevision {
  final String unitKey, emulator, system, owner, title, kind, format;
  final String contentHash, payloadHash, relativeDirectory;
  final int size;
  final DateTime modified;
  final String transferState;
  const SaveRevision({required this.unitKey, required this.emulator, required this.system,
    required this.owner, required this.title, required this.kind, required this.format,
    required this.contentHash, required this.payloadHash, required this.size,
    required this.modified, required this.relativeDirectory, this.transferState = 'pending'});

  // Equal raw bytes from two distinct memory-card slots still need separate
  // durable outbox entries and separate native restore destinations.
  String get storageKey => sha256.convert(utf8.encode('$unitKey\n$payloadHash')).toString();
  String get id => '$relativeDirectory/$payloadHash';
  String get payloadPath => '$id.nssave';
  String get manifestPath => '$id.json';
  static String folder(String text) {
    final clean = text.replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'), '_').trim();
    return clean.isEmpty || clean == '.' || clean == '..' ? 'Unidentified' : clean.substring(0, clean.length > 100 ? 100 : clean.length);
  }

  /// Stable first-level console directory used inside each emulator folder.
  /// These names intentionally match the directories created by the native
  /// iCloud authorization broker so uploads never fork into parallel labels
  /// such as `ARMSX2/PlayStation 2` beside the expected `ARMSX2/PS2`.
  static String consoleFolder(String emulator, String system) {
    if (emulator == 'ARMSX2' && system == 'PlayStation 2') return 'PS2';
    if (emulator == 'RPCS3' && system == 'PlayStation 3') return 'PS3';
    if (emulator == 'DolphiniOS' && system == 'GameCube') return 'GameCube';
    if (emulator == 'DolphiniOS' && system == 'Wii') return 'Wii';
    if (emulator == 'MeloNX' && system == 'Switch') return 'Switch';
    return folder(system);
  }

  static String directoryFor(String emulator, String system, String owner, String kind, String key) =>
      '${folder(emulator)}/${consoleFolder(emulator, system)}/${folder(owner)}/${folder(kind)}/${sha256.convert(utf8.encode(key)).toString().substring(0, 16)}';

  // Build 208 betas could have staged a revision before console-folder names
  // were canonicalized. Keep those manifests readable/restorable while all new
  // writes use [directoryFor].
  static String _legacyDirectoryFor(String emulator, String system, String owner, String kind, String key) =>
      '${folder(emulator)}/${folder(system)}/${folder(owner)}/${folder(kind)}/${sha256.convert(utf8.encode(key)).toString().substring(0, 16)}';

  Map<String, Object> toJson() => {'schema': 1, 'unit': unitKey, 'emulator': emulator,
    'system': system, 'owner': owner, 'title': title, 'kind': kind, 'format': format,
    'contentHash': contentHash, 'payloadHash': payloadHash, 'size': size,
    'modified': modified.toUtc().toIso8601String(), 'directory': relativeDirectory};
  factory SaveRevision.fromJson(Map<String, dynamic> value, {String state = 'pending'}) {
    if (value['schema'] != 1) throw const FormatException('Unknown save manifest version');
    String text(String key) {
      final v = value[key];
      if (v is! String || v.isEmpty || v.length > 2048 || v.contains('\u0000')) {
        throw FormatException('Invalid save manifest $key');
      }
      return v;
    }
    final result = SaveRevision(unitKey: text('unit'), emulator: text('emulator'), system: text('system'),
      owner: text('owner'), title: text('title'), kind: text('kind'), format: text('format'),
      contentHash: text('contentHash'), payloadHash: text('payloadHash'), size: value['size'] as int,
      modified: DateTime.parse(text('modified')), relativeDirectory: text('directory'), transferState: state);
    SaveSnapshot.safeRelative(result.relativeDirectory);
    final canonicalDirectory = directoryFor(result.emulator, result.system, result.owner, result.kind, result.unitKey);
    final legacyDirectory = _legacyDirectoryFor(result.emulator, result.system, result.owner, result.kind, result.unitKey);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(result.contentHash) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(result.payloadHash) || result.size < 1 ||
        result.size > SaveSnapshot.maxBytes + SaveSnapshot.maxHeader + 12 ||
        result.relativeDirectory != canonicalDirectory && result.relativeDirectory != legacyDirectory ||
        !const {'native-v1', 'dolphin-v2'}.contains(result.format)) {
      throw const FormatException('Invalid save revision');
    }
    return result;
  }
}
