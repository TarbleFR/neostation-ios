import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../utils/cloud_path_builder.dart';
import 'dolphin_system_files.dart';

/// Native identity from DiscIO, never inferred from a ROM filename or scraper.
class DolphinSaveIdentity {
  final String system;
  final String gameId;
  final String region;
  final String? titleId;
  const DolphinSaveIdentity({required this.system, required this.gameId,
    required this.region, this.titleId});

  factory DolphinSaveIdentity.fromMap(Map<String, dynamic> value) {
    final result = DolphinSaveIdentity(
      system: value['system']?.toString() ?? '',
      gameId: value['gameId']?.toString() ?? '',
      region: value['region']?.toString() ?? '',
      titleId: value['titleId']?.toString().toLowerCase(),
    );
    if (!result.isValid) throw const FormatException('Dolphin save identity unavailable');
    return result;
  }

  bool get isValid => system == 'gc'
      ? RegExp(r'^[A-Z0-9]{6}$').hasMatch(gameId) && {'USA', 'EUR', 'JAP'}.contains(region)
      : system == 'wii' && RegExp(r'^0001000[014][0-9a-f]{8}$').hasMatch(titleId ?? '');
}

/// Each object is a complete, versioned native save snapshot. GCI objects contain
/// one game's files in one slot; raw cards are explicitly shared; Wii objects
/// contain only a single title's data directory (never NAND/system content).
/// State objects contain exactly one numbered native checkpoint for one game.
class DolphinSaveTarget {
  static const emulator = 'dolphinios';
  final String system;
  final String kind;
  final String identity;
  final String region;
  final String slot;
  final String rawName;
  const DolphinSaveTarget._(this.system, this.kind, this.identity,
    this.region, this.slot, this.rawName);

  static final rawPattern = RegExp(r'^MemoryCard([AB])\.(USA|EUR|JAP)(?:\.[0-9]+)?\.raw$');

  static List<DolphinSaveTarget> forGame(DolphinSaveIdentity game) {
    if (!game.isValid) return [];
    if (game.system == 'gc') {
      return [for (final slot in ['A', 'B'])
        DolphinSaveTarget._('gc', 'gci', game.gameId, game.region, slot, '')];
    }
    return [DolphinSaveTarget._('wii', 'wii-data', game.titleId!, '', '', '')];
  }

  static bool _validStateIdentity(String system, String identity, String gameId) {
    if (system == 'gc') {
      return RegExp(r'^[A-Z0-9]{6}$').hasMatch(gameId) && identity == gameId;
    }
    // Wii discs use six-character IDs; installed game channels can use four.
    // In either case the first four native ID bytes must match the title ID.
    return system == 'wii' &&
        RegExp(r'^0001000[014][0-9a-f]{8}$').hasMatch(identity) &&
        RegExp(r'^[A-Z0-9]{4}(?:[A-Z0-9]{2})?$').hasMatch(gameId) &&
        gameId.substring(0, 4).codeUnits
            .map((byte) => byte.toRadixString(16).padLeft(2, '0')).join() == identity.substring(8);
  }

  static List<DolphinSaveTarget> statesForGame(DolphinSaveIdentity game) {
    final identity = game.system == 'gc' ? game.gameId : game.titleId ?? '';
    if (!game.isValid || !_validStateIdentity(game.system, identity, game.gameId)) return [];
    return [for (var slot = 1; slot <= 10; slot++)
      DolphinSaveTarget._(game.system, 'state', identity, '',
        slot.toString().padLeft(2, '0'), '${game.gameId}.s${slot.toString().padLeft(2, '0')}')];
  }

  static DolphinSaveTarget? raw(String name) {
    final match = rawPattern.firstMatch(name);
    if (match == null) return null;
    return DolphinSaveTarget._('gc', 'raw', '', match[2]!, match[1]!, name);
  }

  bool get shared => kind == 'raw';
  bool get isState => kind == 'state';
  String get objectName => switch (kind) {
    'gci' => 'gci-$region-$slot.nsav',
    'raw' => '$rawName.nsav',
    'state' => '$rawName.nsav',
    _ => 'wii-data.nsav',
  };
  String get relativeNativePath => switch (kind) {
    'gci' => 'GC/$region/Card $slot',
    'raw' => 'GC/$rawName',
    'state' => 'StateSaves/$rawName',
    _ => 'Wii/title/${identity.substring(0, 8)}/${identity.substring(8)}/data',
  };
  String get cloudPath => CloudPathBuilder.build(system: system,
    emulatorSlug: emulator, scope: shared ? 'shared' : 'game',
    gameName: shared ? null : identity, filePath: objectName, isState: isState);

  bool matches(DolphinSaveIdentity game) => system == game.system &&
      (isState ? identity == (system == 'gc' ? game.gameId : game.titleId) &&
          rawName == '${game.gameId}.s$slot' :
       kind == 'wii-data' ? identity == game.titleId :
       region == game.region && (shared || identity == game.gameId));

  /// A strict round trip rejects traversal, extra components and unknown slots.
  static DolphinSaveTarget? parse(String cloudPath) {
    final parsed = CloudPathBuilder.parse(cloudPath);
    if (parsed == null || parsed.emulatorSlug != emulator) return null;
    DolphinSaveTarget? target;
    if (parsed.isState) {
      final match = RegExp(r'^([A-Z0-9]{4}(?:[A-Z0-9]{2})?)\.s(0[1-9]|10)\.nsav$').firstMatch(parsed.filePath);
      if (!parsed.isShared && match != null &&
          _validStateIdentity(parsed.system, parsed.gameName ?? '', match[1]!)) {
        target = DolphinSaveTarget._(parsed.system, 'state', parsed.gameName!, '',
          match[2]!, '${match[1]}.s${match[2]}');
      }
    } else if (parsed.system == 'gc' && parsed.isShared && parsed.filePath.endsWith('.nsav')) {
      target = raw(parsed.filePath.substring(0, parsed.filePath.length - 5));
    } else if (parsed.system == 'gc' && !parsed.isShared &&
        RegExp(r'^[A-Z0-9]{6}$').hasMatch(parsed.gameName ?? '')) {
      final match = RegExp(r'^gci-(USA|EUR|JAP)-([AB])\.nsav$').firstMatch(parsed.filePath);
      if (match != null) target = DolphinSaveTarget._('gc', 'gci', parsed.gameName!, match[1]!, match[2]!, '');
    } else if (parsed.system == 'wii' && !parsed.isShared &&
        RegExp(r'^0001000[014][0-9a-f]{8}$').hasMatch(parsed.gameName ?? '') &&
        parsed.filePath == 'wii-data.nsav') {
      target = DolphinSaveTarget._('wii', 'wii-data', parsed.gameName!, '', '', '');
    }
    return target?.cloudPath == cloudPath ? target : null;
  }

  /// Reserved namespace must never fall through to a RetroArch restore path.
  static bool ownsCloudPath(String value) {
    final parts = value.replaceAll('\\', '/').split('/');
    return parts.length >= 4 && parts[0] == 'v2' &&
        parts[3].toLowerCase() == emulator;
  }
}

/// Display metadata only. Keys are verified native identities, so a filename
/// guess, another console or a shared card cannot receive the wrong game title.
class DolphinSaveTitleCache {
  final Map<String, String> _titles = {};

  void remember(DolphinSaveIdentity game, String title) {
    if (!game.isValid || title.trim().isEmpty) return;
    final identity = game.system == 'gc' ? game.gameId : game.titleId!;
    _titles['${game.system}/$identity'] = title.trim();
  }

  String? titleFor(DolphinSaveTarget target) => target.isState
      ? _titles['${target.system}/${target.identity}'] : null;
}

class DolphinSaveSnapshot {
  final DolphinSaveTarget target;
  final File file;
  final String checksum;
  final DateTime modified;
  final int size;
  const DolphinSaveSnapshot(this.target, this.file, this.checksum, this.modified, this.size);
}

enum DolphinSyncDecision { equal, upload, download, conflict, empty }

/// Three-way CONTENT comparison. Unknown history or two independently changed
/// saves is a conflict; timestamps never authorize destruction of a native save.
DolphinSyncDecision dolphinSyncDecision(String? local, String? remote, String? base) {
  if (local == null && remote == null) return DolphinSyncDecision.empty;
  if (local == remote) return DolphinSyncDecision.equal;
  if (local == null) return DolphinSyncDecision.download;
  if (remote == null) return DolphinSyncDecision.upload;
  if (base != null && local == base) return DolphinSyncDecision.download;
  if (base != null && remote == base) return DolphinSyncDecision.upload;
  return DolphinSyncDecision.conflict;
}

/// Filesystem-only adapter, usable in tests without Flutter, JIT, or an account.
/// The caller must hold DolphinInternalV2Service.withSaveAccess throughout use.
class DolphinSaveStore {
  final Directory userDirectory;
  final Directory cacheDirectory;
  static const maxPayloadBytes = 64 * 1024 * 1024;
  static const maxNativeBytes = 40 * 1024 * 1024;
  // Wii states can exceed the ordinary-save limit. Store native compressed
  // bytes directly rather than multiplying their memory footprint with base64.
  static const maxStateNativeBytes = 192 * 1024 * 1024;
  static const _stateHeaderLimit = 4096;
  static const _stateMagic = 'NSDSV002';
  static int payloadLimit(DolphinSaveTarget target) => target.isState
      ? maxStateNativeBytes + _stateHeaderLimit + 12 : maxPayloadBytes;
  static const maxFiles = 2048;
  DolphinSaveStore(this.userDirectory, this.cacheDirectory);

  static void _safeName(String name) {
    if (name.isEmpty || name.length > 512 || name.contains('\\') ||
        name.contains(':') || name.startsWith('/') || name.contains('\x00') ||
        name.split('/').any((s) => s.isEmpty || s == '.' || s == '..' ||
          RegExp(r'[\x00-\x1f]').hasMatch(s))) {
      throw const FormatException('Unsafe Dolphin save path');
    }
  }

  static Future<void> _noLinks(String root, String destination) async {
    root = p.normalize(p.absolute(root));
    destination = p.normalize(p.absolute(destination));
    if (root != destination && !p.isWithin(root, destination)) {
      throw const FormatException('Dolphin save escaped its private root');
    }
    // Include every ancestor, not just the final leaf. Missing components are
    // allowed for first restore; a symlink at ANY existing component is not.
    var cursor = destination;
    while (true) {
      if (await FileSystemEntity.type(cursor, followLinks: false) == FileSystemEntityType.link) {
        throw const FormatException('Symlink in Dolphin save path');
      }
      if (cursor == root) break;
      cursor = p.dirname(cursor);
    }
  }

  Future<String> nativePath(DolphinSaveTarget target) async {
    final destination = p.join(userDirectory.path, target.relativeNativePath);
    await _noLinks(userDirectory.path, destination);
    return destination;
  }

  Future<File> cacheFile(DolphinSaveTarget target) async {
    final name = sha256.convert(utf8.encode(target.cloudPath)).toString();
    final file = File(p.join(cacheDirectory.path, 'snapshots', '$name.nsav'));
    await _noLinks(cacheDirectory.path, file.path);
    await file.parent.create(recursive: true);
    return file;
  }

  /// Recovery runs before the core starts, including after a process kill
  /// between directory renames. Old native snapshots are retained locally.
  Future<void> recover() async {
    final targets = <String>[
      for (final region in ['USA', 'EUR', 'JAP'])
        for (final slot in ['A', 'B']) 'GC/$region/Card $slot',
    ];
    final titles = Directory(p.join(userDirectory.path, 'Wii/title'));
    await _noLinks(userDirectory.path, titles.path);
    if (await titles.exists()) {
      await for (final type in titles.list(followLinks: false)) {
        if (type is! Directory || !RegExp(r'^0001000[014]$').hasMatch(p.basename(type.path))) continue;
        await for (final title in type.list(followLinks: false)) {
          if (title is Directory && RegExp(r'^[0-9a-f]{8}$').hasMatch(p.basename(title.path))) {
            targets.add(p.relative(p.join(title.path, 'data'), from: userDirectory.path));
          }
        }
      }
    }
    for (final relative in targets) {
      final target = Directory(p.join(userDirectory.path, relative));
      for (final suffix in ['', '.previous', '.incoming']) {
        await _noLinks(userDirectory.path, '${target.path}$suffix');
      }
      await DolphinSystemFiles.recover(target);
    }
  }

  Future<List<DolphinSaveTarget>> targetsForGame(DolphinSaveIdentity game) async {
    final result = [...DolphinSaveTarget.forGame(game), ...DolphinSaveTarget.statesForGame(game)];
    if (game.system == 'gc') {
      final gc = Directory(p.join(userDirectory.path, 'GC'));
      await _noLinks(userDirectory.path, gc.path);
      if (await gc.exists()) {
        await for (final file in gc.list(followLinks: false)) {
          final target = DolphinSaveTarget.raw(p.basename(file.path));
          if (file is File && target != null && target.matches(game)) result.add(target);
        }
      }
    }
    return result;
  }

  static bool _gciOwned(List<int> bytes, String gameId) => bytes.length >= 6 &&
      String.fromCharCodes(bytes.take(6)) == gameId;

  static void _validateFile(DolphinSaveTarget target, String name, List<int> bytes) {
    _safeName(name);
    if (target.kind == 'gci') {
      if (name.contains('/') || !name.toLowerCase().endsWith('.gci') ||
          !_gciOwned(bytes, target.identity) || bytes.length < 64 ||
          bytes.length != 64 + ((bytes[0x38] << 8) | bytes[0x39]) * 8192 ||
          bytes.length == 64) {
        throw const FormatException('Invalid or wrong-game GameCube GCI');
      }
    } else if (target.kind == 'raw') {
      if (name != target.rawName || !{524288, 1048576, 2097152, 4194304, 8388608, 16777216}.contains(bytes.length)) {
        throw const FormatException('Invalid GameCube raw memory card size');
      }
    }
  }

  Future<DolphinSaveSnapshot?> snapshot(DolphinSaveTarget target) =>
      Isolate.run(() => _snapshot(target));

  Future<DolphinSaveSnapshot?> _snapshot(DolphinSaveTarget target) async {
    if (target.isState) return _snapshotState(target);
    final native = await nativePath(target);
    final paths = <File>[];
    final directories = <String>[];
    if (target.shared) {
      if (await File(native).exists()) paths.add(File(native));
    } else if (await Directory(native).exists()) {
      await for (final item in Directory(native).list(recursive: target.kind == 'wii-data', followLinks: false)) {
        if (item is Link) throw const FormatException('Symlink in Dolphin save');
        final name = p.relative(item.path, from: native).replaceAll('\\', '/');
        if (p.basename(name) == '.DS_Store' || p.basename(name).startsWith('._')) continue;
        if (item is Directory && target.kind == 'wii-data') {
          _safeName(name);
          directories.add(name);
          if (directories.length > maxFiles) throw const FormatException('Too many Dolphin save directories');
        }
        if (item is! File) continue;
        if (target.kind == 'gci') {
          if (name.contains('/') || !name.toLowerCase().endsWith('.gci')) continue;
          final input = await item.open();
          List<int> header;
          try { header = await input.read(6); } finally { await input.close(); }
          if (!_gciOwned(header, target.identity)) continue;
        }
        paths.add(item);
        if (paths.length > maxFiles) throw const FormatException('Too many Dolphin save files');
      }
    }
    if (paths.isEmpty) return null;
    paths.sort((a, b) => a.path.compareTo(b.path));
    directories.sort();
    var total = 0;
    var modified = DateTime.fromMillisecondsSinceEpoch(0);
    final files = <Map<String, Object>>[];
    for (final file in paths) {
      await _noLinks(userDirectory.path, file.path);
      final stat = await file.stat();
      total += stat.size;
      if (stat.size > maxNativeBytes || total > maxNativeBytes) throw const FormatException('Dolphin save exceeds size limit');
      final bytes = await file.readAsBytes();
      final name = target.shared ? target.rawName : p.relative(file.path, from: native).replaceAll('\\', '/');
      _validateFile(target, name, bytes);
      final after = await file.stat();
      if (stat.size != after.size || stat.modified != after.modified || bytes.length != stat.size) {
        throw const FileSystemException('Dolphin save changed during snapshot');
      }
      if (stat.modified.isAfter(modified)) modified = stat.modified;
      files.add({'path': name, 'sha256': sha256.convert(bytes).toString(), 'data': base64Encode(bytes)});
    }
    // No date, absolute path, account ID or device identifier in the payload.
    // Identical native content produces identical snapshots across devices.
    final bytes = utf8.encode(jsonEncode({'format': 'neostation.dolphin.save', 'version': 1,
      'key': target.cloudPath, 'directories': directories, 'files': files}));
    if (bytes.length > maxPayloadBytes) throw const FormatException('Dolphin snapshot exceeds size limit');
    final output = await cacheFile(target);
    if (!await output.exists() || md5.convert(await output.readAsBytes()) != md5.convert(bytes)) {
      await _atomicFile(output, bytes);
      await output.setLastModified(modified);
    }
    return DolphinSaveSnapshot(target, output, md5.convert(bytes).toString(), modified, bytes.length);
  }

  static void _validateStateHeader(DolphinSaveTarget target, Uint8List bytes, int size) {
    if (!target.isState || size < 49 || size > maxStateNativeBytes || bytes.length < 48) {
      throw const FormatException('Invalid Dolphin savestate size');
    }
    final gameId = target.rawName.split('.').first;
    final expectedId = Uint8List(6)..setRange(0, gameId.length, ascii.encode(gameId));
    for (var index = 0; index < 6; index++) {
      if (bytes[index] != expectedId[index]) throw const FormatException('Wrong-game Dolphin savestate');
    }
    // Native modern Dolphin StateHeaderLegacy + StateHeaderVersion. Old LZO
    // checkpoints are deliberately unsupported; the core checks state version
    // compatibility when the user loads the restored slot.
    final data = ByteData.sublistView(bytes);
    final cookie = data.getUint32(24, Endian.little);
    final versionLength = data.getUint32(28, Endian.little);
    if (data.getUint32(8, Endian.little) != 0 || cookie <= 0xBAADBABE ||
        cookie > 0xBAADBABE + 10000 || versionLength > 1024 ||
        bytes.length < 48 + versionLength || size <= 48 + versionLength) {
      throw const FormatException('Invalid Dolphin savestate header');
    }
    final extended = 32 + versionLength;
    final compression = data.getUint16(extended + 2, Endian.little);
    final offset = data.getUint32(extended + 4, Endian.little);
    final uncompressedSize = data.getUint64(extended + 8, Endian.little);
    final contentOffset = extended + 16 + offset;
    if (data.getUint16(extended, Endian.little) != 1 || compression > 1 ||
        uncompressedSize == 0 || uncompressedSize > maxStateNativeBytes ||
        contentOffset >= size ||
        (compression == 0 && size - contentOffset != uncompressedSize)) {
      throw const FormatException('Invalid Dolphin savestate payload header');
    }
  }

  Future<DolphinSaveSnapshot?> _snapshotState(DolphinSaveTarget target) async {
    final native = File(await nativePath(target));
    if (!await native.exists()) return null;
    final before = await native.stat();
    final input = await native.open();
    try {
      _validateStateHeader(target, await input.read(4096), before.size);
    } finally { await input.close(); }
    final nativeHash = (await sha256.bind(native.openRead()).single).toString();
    final header = utf8.encode(jsonEncode({
      'format': 'neostation.dolphin.state', 'version': 2,
      'key': target.cloudPath, 'path': target.rawName,
      'size': before.size, 'sha256': nativeHash,
    }));
    if (header.length > _stateHeaderLimit) throw const FormatException('Dolphin state envelope header too large');
    final prefix = Uint8List(12)..setRange(0, 8, ascii.encode(_stateMagic));
    ByteData.sublistView(prefix).setUint32(8, header.length, Endian.little);
    final output = await cacheFile(target);
    final temp = File('${output.path}.incoming-${DateTime.now().microsecondsSinceEpoch}');
    await _noLinks(cacheDirectory.path, temp.path);
    try {
      final sink = temp.openWrite();
      try {
        sink.add(prefix);
        sink.add(header);
        await sink.addStream(native.openRead());
        await sink.flush();
      } finally { await sink.close(); }
      final after = await native.stat();
      final nativeOffset = 12 + header.length;
      if (before.size != after.size || before.modified != after.modified ||
          await temp.length() != nativeOffset + before.size ||
          (await sha256.bind(temp.openRead(nativeOffset)).single).toString() != nativeHash) {
        throw const FileSystemException('Dolphin savestate changed during snapshot');
      }
      final checksum = (await md5.bind(temp.openRead()).single).toString();
      final unchanged = await output.exists() &&
          (await md5.bind(output.openRead()).single).toString() == checksum;
      if (!unchanged) {
        await temp.rename(output.path);
        await output.setLastModified(before.modified);
      }
      return DolphinSaveSnapshot(target, output, checksum, before.modified, nativeOffset + before.size);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> _restoreState(DolphinSaveTarget target, List<int> payload) async {
    // The single Uint8List view avoids copying a Wii state or decoding a
    // base64 string while the authenticated transport already owns the bytes.
    final bytes = payload is Uint8List ? payload : Uint8List.fromList(payload);
    if (bytes.length < 12 || ascii.decode(bytes.sublist(0, 8), allowInvalid: true) != _stateMagic) {
      throw const FormatException('Incompatible Dolphin state envelope');
    }
    final headerLength = ByteData.sublistView(bytes).getUint32(8, Endian.little);
    if (headerLength == 0 || headerLength > _stateHeaderLimit || bytes.length <= 12 + headerLength) {
      throw const FormatException('Invalid Dolphin state envelope length');
    }
    final header = jsonDecode(utf8.decode(Uint8List.sublistView(bytes, 12, 12 + headerLength)));
    final nativeBytes = Uint8List.sublistView(bytes, 12 + headerLength);
    if (header is! Map || header['format'] != 'neostation.dolphin.state' ||
        header['version'] != 2 || header['key'] != target.cloudPath ||
        header['path'] != target.rawName || header['size'] != nativeBytes.length ||
        header['sha256'] != sha256.convert(nativeBytes).toString()) {
      throw const FormatException('Corrupt or wrong-game Dolphin state envelope');
    }
    _validateStateHeader(target, nativeBytes, nativeBytes.length);
    final native = await nativePath(target);
    final live = File(native);
    await live.parent.create(recursive: true);
    if (await live.exists()) {
      final backup = File('$native.neostation-previous-${DateTime.now().microsecondsSinceEpoch}');
      await _noLinks(userDirectory.path, backup.path);
      await live.copy(backup.path);
    }
    // A same-directory rename atomically replaces only this slot. Backups and
    // unfinished temporary writes are never candidates for synchronization.
    await _atomicFile(live, nativeBytes);
  }

  Future<void> restore(DolphinSaveTarget target, List<int> payload, {required String checksum}) =>
      Isolate.run(() => _restore(target, payload, checksum: checksum));

  Future<void> _restore(DolphinSaveTarget target, List<int> payload, {required String checksum}) async {
    if (payload.isEmpty || payload.length > payloadLimit(target) ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(checksum) || md5.convert(payload).toString() != checksum) {
      throw const FormatException('Dolphin cloud snapshot checksum or size is invalid');
    }
    if (target.isState) {
      await _restoreState(target, payload);
      return;
    }
    final doc = jsonDecode(utf8.decode(payload));
    if (doc is! Map || doc['format'] != 'neostation.dolphin.save' || doc['version'] != 1 || doc['key'] != target.cloudPath) {
      throw const FormatException('Incompatible or wrong-game Dolphin snapshot');
    }
    final entries = doc['files'];
    if (entries is! List || entries.isEmpty || entries.length > maxFiles) throw const FormatException('Invalid Dolphin save manifest');
    final files = <String, Uint8List>{};
    final folded = <String>{};
    final directories = doc['directories'];
    if (directories is! List || directories.length > maxFiles ||
        (target.kind != 'wii-data' && directories.isNotEmpty)) {
      throw const FormatException('Invalid Dolphin save directories');
    }
    for (final directory in directories) {
      if (directory is! String) throw const FormatException('Invalid Dolphin directory');
      _safeName(directory);
      if (!folded.add(directory.toLowerCase())) throw const FormatException('Duplicate Dolphin directory');
    }
    var total = 0;
    for (final entry in entries) {
      if (entry is! Map || entry['path'] is! String || entry['data'] is! String || entry['sha256'] is! String) {
        throw const FormatException('Malformed Dolphin save entry');
      }
      final name = entry['path'] as String;
      _safeName(name);
      if (!folded.add(name.toLowerCase())) throw const FormatException('Duplicate Dolphin save path');
      final bytes = base64Decode(entry['data'] as String);
      total += bytes.length;
      if (total > maxNativeBytes) throw const FormatException('Dolphin native save exceeds size limit');
      if (sha256.convert(bytes).toString() != entry['sha256']) throw const FormatException('Corrupt Dolphin save entry');
      _validateFile(target, name, bytes);
      files[name] = bytes;
    }
    if (target.shared && files.length != 1) throw const FormatException('Raw card manifest must have one file');
    for (final name in files.keys) {
      if (folded.any((other) => other.startsWith('${name.toLowerCase()}/'))) throw const FormatException('Conflicting Dolphin save paths');
    }
    // All validation above completes before any live save is changed.
    final native = await nativePath(target);
    if (target.shared) {
      final live = File(native);
      await live.parent.create(recursive: true);
      if (await live.exists()) {
        final backup = File('$native.neostation-previous-${DateTime.now().microsecondsSinceEpoch}');
        await _noLinks(userDirectory.path, backup.path);
        await live.copy(backup.path);
      }
      await _atomicFile(live, files.values.single);
    } else {
      for (final suffix in ['.previous', '.incoming']) {
        await _noLinks(userDirectory.path, '$native$suffix');
      }
      // A GCI slot may contain other games. Copy them verbatim, but replace all
      // files belonging to THIS game's header identity as one transaction.
      await DolphinSystemFiles.replaceSnapshot(Directory(native), (stage) async {
        if (target.kind == 'gci' && await Directory(native).exists()) {
          await DolphinSystemFiles.copyTree(Directory(native), stage.path);
          await for (final file in stage.list(followLinks: false)) {
            if (file is File && file.path.toLowerCase().endsWith('.gci')) {
              final input = await file.open();
              List<int> header;
              try { header = await input.read(6); } finally { await input.close(); }
              if (_gciOwned(header, target.identity)) await file.delete();
            }
          }
        }
        for (final directory in directories.cast<String>()) {
          await Directory(p.join(stage.path, directory)).create(recursive: true);
        }
        for (final entry in files.entries) {
          final destination = File(p.join(stage.path, entry.key));
          // Do not overwrite another game's GCI just because its filename is
          // identical to the incoming file. Header ownership is authoritative.
          if (target.kind == 'gci' && await destination.exists()) {
            throw const FormatException('GCI filename belongs to another game');
          }
          await destination.parent.create(recursive: true);
          await destination.writeAsBytes(entry.value, flush: true);
        }
        return files.length;
      });
    }
  }

  Future<String?> lastCommonHash(String account, DolphinSaveTarget target) async {
    final file = await _ledgerFile(account, target);
    if (!await file.exists()) return null;
    final hash = (await file.readAsString()).trim();
    return RegExp(r'^[a-f0-9]{32}$').hasMatch(hash) ? hash : null;
  }

  Future<void> remember(String account, DolphinSaveTarget target, String hash) async {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(hash)) throw const FormatException('Invalid common hash');
    await _atomicFile(await _ledgerFile(account, target), utf8.encode(hash));
  }

  Future<File> _ledgerFile(String account, DolphinSaveTarget target) async {
    if (account.isEmpty) throw const FormatException('Save destination identity missing');
    final key = sha256.convert(utf8.encode('$account\n${target.cloudPath}'));
    final file = File(p.join(cacheDirectory.path, 'history', '$key.txt'));
    await _noLinks(cacheDirectory.path, file.path);
    await file.parent.create(recursive: true);
    return file;
  }

  static Future<void> _atomicFile(File file, List<int> data) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.incoming-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await temp.writeAsBytes(data, flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}
