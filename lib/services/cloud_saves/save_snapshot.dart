import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Streaming, versioned container. It preserves complete native save units,
/// including extensionless files, empty folders and native modification dates.
/// Emulator working folders are never moved into iCloud Drive.
class SaveSnapshot {
  static const magic = 'NSCS0001';
  static const maxBytes = 512 * 1024 * 1024;
  static const maxMembers = 8192;
  static const maxHeader = 2 * 1024 * 1024;
  final File file;
  final String contentHash;
  final String payloadHash;
  final int size;
  final DateTime modified;
  const SaveSnapshot(this.file, this.contentHash, this.payloadHash, this.size, this.modified);

  // Keep isolate closure contexts in these small, transport-only methods.
  // Capturing a caller's async frame also captures MethodChannels/Completers.
  static Future<SaveSnapshot> createOffMain(String source, String output, String unit) =>
      Isolate.run(() => create(source, File(output), unit));
  static Future<({String path, bool directory})> unpackOffMain(String payload,
      String staging, String unit, String payloadHash, String contentHash) =>
      Isolate.run(() => unpack(File(payload), Directory(staging), unitKey: unit,
        payloadHash: payloadHash, contentHash: contentHash));

  static Future<String> hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  static void safeRelative(String value) {
    if (value.isEmpty || value.length > 1024 || value.contains('\\') ||
        value.contains(':') || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value) ||
        value.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw const FormatException('Unsafe save member path');
    }
  }

  static Future<void> noLinks(String root, String target) async {
    root = p.normalize(p.absolute(root));
    var cursor = p.normalize(p.absolute(target));
    if (cursor != root && !p.isWithin(root, cursor)) {
      throw const FormatException('Save escaped authorized root');
    }
    while (true) {
      if (await FileSystemEntity.type(cursor, followLinks: false) == FileSystemEntityType.link) {
        throw const FormatException('Symbolic link in save');
      }
      if (cursor == root) break;
      cursor = p.dirname(cursor);
    }
  }

  static Future<SaveSnapshot> create(String source, File output, String unitKey) async {
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type != FileSystemEntityType.file && type != FileSystemEntityType.directory) {
      throw const FileSystemException('Save unit is missing or is a link');
    }
    final isDirectory = type == FileSystemEntityType.directory;
    final root = isDirectory ? source : p.dirname(source);
    final files = <File>[];
    final directories = <String>[];
    if (isDirectory) {
      await for (final entry in Directory(source).list(recursive: true, followLinks: false)) {
        await noLinks(root, entry.path);
        final relative = p.relative(entry.path, from: root).replaceAll('\\', '/');
        safeRelative(relative);
        if (entry is File) files.add(entry);
        if (entry is Directory) directories.add(relative);
        if (files.length + directories.length > maxMembers) {
          throw const FormatException('Save has too many members');
        }
      }
    } else {
      await noLinks(root, source);
      files.add(File(source));
    }
    if (files.isEmpty) throw const FormatException('Empty save unit');
    final folded = <String>{};
    for (final name in [...directories, for (final f in files) isDirectory ? p.relative(f.path, from: root).replaceAll('\\', '/') : 'data']) {
      if (!folded.add(name.toLowerCase())) throw const FormatException('Case-colliding save members');
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    directories.sort();
    var total = 0;
    var modified = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final entries = <Map<String, Object>>[];
    for (final file in files) {
      final before = await file.stat();
      total += before.size;
      if (total > maxBytes) throw const FormatException('Save exceeds 512 MiB limit');
      final digest = await hash(file);
      final after = await file.stat();
      if (before.size != after.size || before.modified != after.modified) {
        throw const FileSystemException('Save changed during snapshot');
      }
      if (before.modified.isAfter(modified)) modified = before.modified.toUtc();
      entries.add({'path': isDirectory ? p.relative(file.path, from: root).replaceAll('\\', '/') : 'data',
        'size': before.size, 'sha256': digest, 'modified': before.modified.toUtc().toIso8601String()});
    }
    final fingerprint = {'unit': unitKey, 'directory': isDirectory, 'directories': directories,
      'files': [for (final e in entries) {'path': e['path'], 'size': e['size'], 'sha256': e['sha256']}]};
    final contentHash = sha256.convert(utf8.encode(jsonEncode(fingerprint))).toString();
    final header = utf8.encode(jsonEncode({'schema': 1, 'unit': unitKey,
      'directory': isDirectory, 'directories': directories, 'files': entries}));
    if (header.length > maxHeader) throw const FormatException('Save header too large');
    await output.parent.create(recursive: true);
    final handle = await output.open(mode: FileMode.write);
    try {
      await handle.writeFrom(ascii.encode(magic));
      await handle.writeFrom((ByteData(4)..setUint32(0, header.length, Endian.big)).buffer.asUint8List());
      await handle.writeFrom(header);
      for (var i = 0; i < files.length; i++) {
        await for (final chunk in files[i].openRead()) { await handle.writeFrom(chunk); }
        // Detect non-cooperating external emulators even if their mtime is coarse.
        if (await hash(files[i]) != entries[i]['sha256']) {
          throw const FileSystemException('Save changed while being copied');
        }
      }
      await handle.flush();
    } finally { await handle.close(); }
    return SaveSnapshot(output, contentHash, await hash(output), await output.length(), modified);
  }

  /// Decode only into a fresh private staging directory. Native destinations
  /// are resolved from the local adapter, NEVER from a path in cloud metadata.
  static Future<({String path, bool directory})> unpack(File file, Directory staging,
      {required String unitKey, required String payloadHash, required String contentHash}) async {
    if (await file.length() > maxBytes + maxHeader + 12 || await hash(file) != payloadHash) {
      throw const FormatException('Save checksum or size mismatch');
    }
    final input = await file.open();
    try {
      if (ascii.decode(await input.read(8), allowInvalid: true) != magic) {
        throw const FormatException('Unsupported save container');
      }
      final lengthBytes = await input.read(4);
      if (lengthBytes.length != 4) throw const FormatException('Truncated save');
      final length = ByteData.sublistView(lengthBytes).getUint32(0, Endian.big);
      if (length == 0 || length > maxHeader) throw const FormatException('Invalid save header');
      final headerBytes = await input.read(length);
      if (headerBytes.length != length) throw const FormatException('Truncated save header');
      final header = jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
      if (header['schema'] != 1 || header['unit'] != unitKey || header['directory'] is! bool) {
        throw const FormatException('Wrong save identity or format');
      }
      final entries = (header['files'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final directories = List<String>.from(header['directories'] as List);
      if (entries.isEmpty || entries.length + directories.length > maxMembers) {
        throw const FormatException('Invalid member count');
      }
      final names = <String>{};
      var total = 0;
      for (final directory in directories) { safeRelative(directory); if (!names.add(directory.toLowerCase())) throw const FormatException('Duplicate member'); }
      for (final e in entries) {
        final name = e['path'] as String;
        safeRelative(name);
        if (!names.add(name.toLowerCase()) || e['size'] is! int || (e['size'] as int) < 0 ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(e['sha256'] as String)) {
          throw const FormatException('Invalid save member');
        }
        total += e['size'] as int;
        if (total > maxBytes) throw const FormatException('Oversized save');
      }
      if (header['directory'] == false && (entries.length != 1 || entries.single['path'] != 'data' || directories.isNotEmpty)) {
        throw const FormatException('Invalid single-file save');
      }
      for (final e in entries) {
        if (names.any((n) => n.startsWith('${e['path']}/'.toLowerCase()))) throw const FormatException('File/directory collision');
      }
      final fingerprint = {'unit': unitKey, 'directory': header['directory'], 'directories': directories,
        'files': [for (final e in entries) {'path': e['path'], 'size': e['size'], 'sha256': e['sha256']}]};
      if (sha256.convert(utf8.encode(jsonEncode(fingerprint))).toString() != contentHash ||
          12 + length + total != await file.length()) throw const FormatException('Invalid save content');
      if (await staging.exists()) throw const FileSystemException('Restore staging already exists');
      await staging.create(recursive: true);
      for (final name in directories) { await Directory(p.join(staging.path, name)).create(recursive: true); }
      for (final e in entries) {
        final target = File(p.join(staging.path, e['path'] as String));
        await noLinks(staging.path, target.path);
        await target.parent.create(recursive: true);
        final output = await target.open(mode: FileMode.write);
        try {
          var left = e['size'] as int;
          while (left > 0) {
            final chunk = await input.read(left > 65536 ? 65536 : left);
            if (chunk.isEmpty) throw const FormatException('Truncated save payload');
            await output.writeFrom(chunk); left -= chunk.length;
          }
          await output.flush();
        } finally { await output.close(); }
        if (await hash(target) != e['sha256']) throw const FormatException('Save member checksum mismatch');
        await target.setLastModified(DateTime.parse(e['modified'] as String));
      }
      return (path: header['directory'] == true ? staging.path : p.join(staging.path, 'data'),
        directory: header['directory'] as bool);
    } finally { await input.close(); }
  }
}
