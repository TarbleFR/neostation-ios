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
      ? RegExp(r'^[A-Z0-9]{6}$').hasMatch(gameId) &&
          const {'USA', 'EUR', 'JAP'}.contains(region)
      : system == 'wii' &&
          RegExp(r'^0001000[014][0-9a-f]{8}$').hasMatch(titleId ?? '');
}

/// Strict NeoSync V1 scope for the embedded DolphiniOS core:
///
/// * GameCube synchronizes only the two regional memory-card `.raw` files.
/// * Wii synchronizes only one verified title's `00010000/<title>/data` tree.
///
/// GCI folders, savestates and the rest of the Wii NAND are intentionally not
/// addressable. Historical cloud objects remain reserved by [ownsCloudPath],
/// but cannot be parsed into a live restore target.
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

  static final rawPattern =
      RegExp(r'^MemoryCard([AB])\.(USA|EUR|JAP)\.raw$');

  static bool _supportsWiiV1(DolphinSaveIdentity game) {
    if (game.system != 'wii' ||
        !RegExp(r'^[A-Z0-9]{4}(?:[A-Z0-9]{2})?$').hasMatch(game.gameId) ||
        !RegExp(r'^00010000[0-9a-f]{8}$').hasMatch(game.titleId ?? '')) {
      return false;
    }
    final gameIdHex = game.gameId.substring(0, 4).codeUnits
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return game.titleId!.substring(8) == gameIdHex;
  }

  static List<DolphinSaveTarget> forGame(DolphinSaveIdentity game) {
    if (!game.isValid) return [];
    if (game.system == 'gc') {
      return [
        for (final slot in ['A', 'B'])
          DolphinSaveTarget.raw('MemoryCard$slot.${game.region}.raw')!,
      ];
    }
    if (!_supportsWiiV1(game)) return [];
    return [DolphinSaveTarget._('wii', 'wii-data', game.titleId!, '', '', '')];
  }

  /// Kept as a dormant compatibility seam. NeoSync V1 never creates or
  /// restores Dolphin savestate targets.
  static List<DolphinSaveTarget> statesForGame(DolphinSaveIdentity game) =>
      const <DolphinSaveTarget>[];

  static DolphinSaveTarget? raw(String name) {
    final match = rawPattern.firstMatch(name);
    if (match == null) return null;
    return DolphinSaveTarget._('gc', 'raw', '', match[2]!, match[1]!, name);
  }

  bool get shared => kind == 'raw';
  bool get isState => false;
  String get objectName => switch (kind) {
    'raw' => '$rawName.nsav',
    _ => 'wii-data.nsav',
  };
  String get relativeNativePath => switch (kind) {
    'raw' => 'GC/$rawName',
    _ => 'Wii/title/${identity.substring(0, 8)}/${identity.substring(8)}/data',
  };
  String get cloudPath => CloudPathBuilder.build(system: system,
    emulatorSlug: emulator, scope: shared ? 'shared' : 'game',
    gameName: shared ? null : identity, filePath: objectName, isState: isState);

  bool matches(DolphinSaveIdentity game) => game.isValid &&
      system == game.system &&
      (kind == 'wii-data'
          ? _supportsWiiV1(game) && identity == game.titleId
          : kind == 'raw' && region == game.region);

  /// A strict round trip rejects traversal, extra components and unknown slots.
  static DolphinSaveTarget? parse(String cloudPath) {
    final parsed = CloudPathBuilder.parse(cloudPath);
    if (parsed == null || parsed.emulatorSlug != emulator || parsed.isState) {
      return null;
    }
    DolphinSaveTarget? target;
    if (parsed.system == 'gc' && parsed.isShared &&
        parsed.filePath.endsWith('.nsav')) {
      target = raw(parsed.filePath.substring(0, parsed.filePath.length - 5));
    } else if (parsed.system == 'wii' && !parsed.isShared &&
        RegExp(r'^00010000[0-9a-f]{8}$').hasMatch(parsed.gameName ?? '') &&
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
class DolphinNeoSyncStore {
  final Directory userDirectory;
  final Directory cacheDirectory;
  static const maxPayloadBytes = 64 * 1024 * 1024;
  static const maxNativeBytes = 40 * 1024 * 1024;
  static int payloadLimit(DolphinSaveTarget target) => maxPayloadBytes;
  static const maxFiles = 2048;
  DolphinNeoSyncStore(this.userDirectory, this.cacheDirectory);

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
    final targets = <String>[];
    final titles = Directory(p.join(userDirectory.path, 'Wii/title/00010000'));
    await _noLinks(userDirectory.path, titles.path);
    if (await titles.exists()) {
      await for (final title in titles.list(followLinks: false)) {
        if (title is Directory &&
            RegExp(r'^[0-9a-f]{8}$').hasMatch(p.basename(title.path))) {
          targets.add(
            p.relative(p.join(title.path, 'data'), from: userDirectory.path),
          );
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

  Future<List<DolphinSaveTarget>> targetsForGame(DolphinSaveIdentity game) async =>
      DolphinSaveTarget.forGame(game);

  static void _validateFile(DolphinSaveTarget target, String name, List<int> bytes) {
    _safeName(name);
    if (target.kind == 'raw') {
      if (name != target.rawName || !{524288, 1048576, 2097152, 4194304, 8388608, 16777216}.contains(bytes.length)) {
        throw const FormatException('Invalid GameCube raw memory card size');
      }
    } else if (target.kind != 'wii-data') {
      throw const FormatException('Unsupported Dolphin NeoSync target');
    }
  }

  Future<DolphinSaveSnapshot?> snapshot(DolphinSaveTarget target) =>
      Isolate.run(() => _snapshot(target));

  Future<DolphinSaveSnapshot?> _snapshot(DolphinSaveTarget target) async {
    final native = await nativePath(target);
    final paths = <File>[];
    final directories = <String>[];
    if (target.shared) {
      if (await File(native).exists()) paths.add(File(native));
    } else if (target.kind == 'wii-data' && await Directory(native).exists()) {
      await for (final item in Directory(native).list(
          recursive: true, followLinks: false)) {
        if (item is Link) throw const FormatException('Symlink in Dolphin save');
        final name = p.relative(item.path, from: native).replaceAll('\\', '/');
        if (p.basename(name) == '.DS_Store' || p.basename(name).startsWith('._')) continue;
        if (item is Directory) {
          _safeName(name);
          directories.add(name);
          if (directories.length > maxFiles) throw const FormatException('Too many Dolphin save directories');
        }
        if (item is! File) continue;
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

  Future<void> restore(DolphinSaveTarget target, List<int> payload, {required String checksum}) =>
      Isolate.run(() => _restore(target, payload, checksum: checksum));

  Future<void> _restore(DolphinSaveTarget target, List<int> payload, {required String checksum}) async {
    if (payload.isEmpty || payload.length > payloadLimit(target) ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(checksum) || md5.convert(payload).toString() != checksum) {
      throw const FormatException('Dolphin cloud snapshot checksum or size is invalid');
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
        final backup = File('$native.neosync-previous-${DateTime.now().microsecondsSinceEpoch}');
        await _noLinks(userDirectory.path, backup.path);
        await live.copy(backup.path);
      }
      await _atomicFile(live, files.values.single);
    } else {
      for (final suffix in ['.previous', '.incoming']) {
        await _noLinks(userDirectory.path, '$native$suffix');
      }
      // The target is one verified Wii title's data directory. The staged
      // directory swap cannot alter an adjacent title or any other NAND path.
      await DolphinSystemFiles.replaceSnapshot(Directory(native), (stage) async {
        for (final directory in directories.cast<String>()) {
          await Directory(p.join(stage.path, directory)).create(recursive: true);
        }
        for (final entry in files.entries) {
          final destination = File(p.join(stage.path, entry.key));
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
    if (account.isEmpty) throw const FormatException('NeoSync account identity missing');
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
