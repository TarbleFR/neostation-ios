import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as path;

class SwitchSaveLayout {
  static bool safe(String value) => !value.contains('\u0000') && !value.split('/').any((s) => s == '.' || s == '..' || s.isEmpty);
  static MeloNXSaveLocation? melonxSaveLocation(String filePath, String root) {
    final file = filePath.replaceAll('\\', '/');
    final base = root.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    if (!file.startsWith('$base/') ||
        !safe(file.replaceFirst(RegExp(r'^/'), '')) ||
        _package(file) || _hostJunk(file)) return null;

    // Compatibility with older title-ID trees. This is not the native LibHac
    // SaveDataId format, so it must never be used to infer numeric save IDs.
    final old = RegExp(
      r'(?:^|/)user/save/0000000000000000/(?:([0-9a-fA-F]{32}|[0-9a-fA-F]{16})/)?(01[0-9a-fA-F]{14})/(.+)$',
    ).firstMatch(file);
    if (old != null && old[2]!.toLowerCase().endsWith('000')) {
      final payload = old[3]!;
      final payloadRoot = file.substring(0, file.length - payload.length - 1);
      return MeloNXSaveLocation(titleId: old[2]!,
          profileId: old[1]?.toLowerCase() ?? '00000000000000000000000000000000',
          saveId: '0000000000000000', saveRoot: payloadRoot,
          payloadRoot: payloadRoot, payloadPath: payload, legacy: true);
    }

    // LibHac DirectorySaveDataFileSystem: /0 committed, /1 working, /_ syncing.
    // Only committed Account or Device saves qualify. ExtraData metadata is
    // read to identify the native save, never uploaded as a separate save row.
    final match = RegExp(r'(?:^|/)user/save/([0-9a-fA-F]{16})/([01])/(.+)$')
        .firstMatch(file);
    if (match == null || match[1] == '0000000000000000') return null;
    final payload = match[3]!;
    final payloadRoot = file.substring(0, file.length - payload.length - 1);
    final saveRoot = path.posix.dirname(payloadRoot);
    final committed = match[2] == '0';
    final extra = File('$saveRoot/ExtraData${committed ? '0' : '1'}');
    try {
      if (FileSystemEntity.typeSync(extra.path, followLinks: false) !=
          FileSystemEntityType.file || extra.lengthSync() != 0x200) return null;
      final before = extra.statSync();
      final bytes = extra.readAsBytesSync();
      final after = extra.statSync();
      if (bytes.length != 0x200 || before.size != after.size ||
          before.modified != after.modified) return null;
      final data = ByteData.sublistView(bytes);
      final type = data.getUint8(0x20);
      final rank = data.getUint8(0x21);
      final format = data.getUint32(0x54, Endian.little);
      if ((type != 1 && type != 3) || rank > 1 || format > 1) return null;
      // Working-only payload is authoritative solely for non-journal saves.
      if (!committed && (format != 1 || Directory('$saveRoot/0').existsSync())) {
        return null;
      }
      if (Directory('$saveRoot/_').existsSync() ||
          File('$saveRoot/ExtraData_').existsSync()) return null;
      final title = data.getUint64(0, Endian.little)
          .toRadixString(16).padLeft(16, '0').toUpperCase();
      if (!RegExp(r'^01[0-9A-F]{14}$').hasMatch(title)) return null;
      final profile = bytes.sublist(8, 24)
          .map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (type == 1 && profile == '00000000000000000000000000000000') return null;
      return MeloNXSaveLocation(titleId: title, profileId: profile,
          saveId: match[1]!.toLowerCase(), saveRoot: saveRoot,
          payloadRoot: payloadRoot, payloadPath: payload);
    } on FileSystemException {
      return null;
    }
  }

  /// Candidate save roots below a linked MeloNX app/bis/user/save directory.
  /// Never recursively searches installed content, game or DLC directories.
  static List<String> melonxSaveRoots(String root) {
    final base = root.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final candidates = <String>['$base/bis/user/save', '$base/user/save'];
    if (base.endsWith('/user')) candidates.add('$base/save');
    if (RegExp(r'/user/save(?:/.*)?$').hasMatch(base)) candidates.add(base);
    return candidates.where((p) => Directory(p).existsSync()).toSet().toList();
  }

  static bool _package(String value) => RegExp(
    r'\.(?:nca|nsp|nsz|xci|xcz|nro|pkg|rap|rif|iso|cso|chd|gcm|rvz|wbfs|wad|rom|nes|gb|gbc|gba|nds|3ds|cia|elf|dol|exe|dll|dylib|so|ipa)$',
    caseSensitive: false,
  ).hasMatch(value);

  static bool _hostJunk(String value) => value.split('/').any((part) =>
      part.toLowerCase() == '.ds_store' || part.startsWith('._') ||
      part.toLowerCase() == 'thumbs.db' || part == '__MACOSX' ||
      part.startsWith('.neostation-'));

}

class MeloNXSaveLocation {
  const MeloNXSaveLocation({required this.titleId, required this.profileId,
    required this.saveId, required this.saveRoot, required this.payloadRoot,
    required this.payloadPath, this.legacy = false});
  final String titleId;
  final String profileId;
  final String saveId;
  final String saveRoot;
  final String payloadRoot;
  final String payloadPath;
  final bool legacy;
  String get cloudFilePath => legacy
      ? payloadPath
      : 'profiles/$profileId/$titleId/$saveId/$payloadPath';
}
