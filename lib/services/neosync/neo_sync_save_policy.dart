import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import '../../utils/cloud_path_builder.dart';
import '../dolphin_neosync_store.dart';

enum NeoSyncSaveKind { save, foreign, unresolved }

/// One policy for uploads, restoration and cleanup. A filename alone cannot
/// identify a PlayStation savedata component. Unknown historical objects must
/// be investigated, never silently deleted as if they were proven non-saves.
class NeoSyncSavePolicy {
  /// The older PSP catalog predates the iOS RetroArch savedata adapter.
  /// Use the same effective support flag in discovery and the status icon.
  static bool supportsSystem(String system, bool catalogEnabled, {bool? isIOS}) =>
      catalogEnabled || ((isIOS ?? Platform.isIOS) &&
          const {'psp', 'pspminis'}.contains(system.toLowerCase()));

  static const playStationComponents = {
    'param.sfo', 'param.pfd', 'icon0.png', 'icon1.pmf', 'pic0.png',
    'pic1.png', 'snd0.at3', 'sysdata', 'playdata',
  };

  static String unwrap(String value) {
    final normalized = value.replaceAll('\\', '/');
    return normalized.toLowerCase().endsWith('.neosync.gz')
        ? normalized.substring(0, normalized.length - 11) : normalized;
  }

  static bool safe(String value) => !value.contains('\u0000') &&
      !value.split('/').any((s) => s == '.' || s == '..' || s.isEmpty);

  static ParsedCloudPath? canonical(String value) {
    final key = unwrap(value);
    if (!safe(key)) return null;
    final parsed = CloudPathBuilder.parse(key);
    if (parsed == null || (parsed.scope == 'game' && parsed.gameName == null)) {
      return null;
    }
    return parsed;
  }

  static bool isRpcs3Payload(String value) {
    final p = canonical(value);
    return p != null && !p.isState && p.system == 'ps3' &&
        p.emulatorSlug == 'rpcs3' && p.scope == 'game' &&
        RegExp(r'^[0-9]{8}/[^/]+/.+$').hasMatch(p.filePath);
  }

  /// The original native PS3 format is a savedata directory containing its
  /// metadata, images and game data, not an image or a newly invented file type.
  static String? rpcs3NativePath(String value) {
    if (!isRpcs3Payload(value)) return null;
    final parts = canonical(value)!.filePath.split('/');
    return 'dev_hdd0/home/${parts.first}/savedata/${parts.skip(1).join('/')}';
  }

  static ({String titleId, String internalPath})? melonxLocation(
    String filePath, String root,
  ) {
    final location = melonxSaveLocation(filePath, root);
    return location == null ? null
        : (titleId: location.titleId, internalPath: location.cloudFilePath);
  }

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
      part.startsWith('.neosync-restore-'));

  static bool _standaloneSave(String leaf) => RegExp(
    r'\.(?:srm|sav|sra|rtc|eep|fla|mcr|mcd|mcdx|ps2|vmu|nv|nvm|dsv|gci|raw|bcr|bkr|smpc|p2s|ppst|sgm|freeze|savestate|state(?:\.?[0-9]+|\.auto)?|ss[0-9]+|st[0-9]+|s[0-9]{2})(?:\.gz)?$',
    caseSensitive: false,
  ).hasMatch(leaf);

  static NeoSyncSaveKind classify(String value) {
    final key = unwrap(value);
    final relative = key.replaceFirst(RegExp(r'^/'), '');
    if (!safe(relative)) return NeoSyncSaveKind.unresolved;
    final leaf = key.split('/').last.toLowerCase();
    if (_hostJunk(key)) return NeoSyncSaveKind.foreign;
    final p = canonical(key);
    // A native savedata bundle can legitimately contain PNG/SFO, extensionless
    // files, JSON or other game-specific formats. Preserve its complete payload.
    if (isRpcs3Payload(key) || RegExp(
      r'(?:^|/)dev_hdd0/home/[0-9]{8}/savedata/[^/]+/.+$',
      caseSensitive: false,
    ).hasMatch(key) || RegExp(
      r'(?:^|/)PSP/SAVEDATA/[^/]+/.+$', caseSensitive: false,
    ).hasMatch(key)) return NeoSyncSaveKind.save;
    if (p != null && !p.isState && const {'psp', 'pspminis'}.contains(p.system) &&
        p.scope == 'game' && p.filePath.split('/').length >= 2 &&
        RegExp(r'^[A-Z]{4}[0-9]{5}').hasMatch(p.filePath)) {
      return NeoSyncSaveKind.save;
    }
    if (p != null && !p.isState && p.system == 'ps2' &&
        RegExp(r'^(?:memcards/)?[^/]+/[^/]+/.+$').hasMatch(p.filePath) &&
        (p.emulatorSlug == 'armsx2' || p.emulatorSlug.startsWith('retroarch.'))) {
      return _package(key) ? NeoSyncSaveKind.foreign : NeoSyncSaveKind.save;
    }
    if (p != null && !p.isState && const {'psp', 'pspminis'}.contains(p.system) &&
        RegExp(r'^(?:PSP/)?SAVEDATA/[^/]+/.+$', caseSensitive: false)
            .hasMatch(p.filePath)) return NeoSyncSaveKind.save;
    if (RegExp(r'(?:^|/)PSP/(?:GAME|TEXTURES|SYSTEM|flash0|Cheats)/',
        caseSensitive: false).hasMatch(p?.filePath ?? key)) return NeoSyncSaveKind.foreign;
    if (_package(key)) return NeoSyncSaveKind.foreign;
    if (DolphinSaveTarget.parse(key) != null) return NeoSyncSaveKind.save;
    if (p?.emulatorSlug == 'dolphinios') return NeoSyncSaveKind.unresolved;
    if (_standaloneSave(leaf) ||
        RegExp(r'^vmu_save[^/]*\.bin$', caseSensitive: false).hasMatch(leaf)) {
      return NeoSyncSaveKind.save;
    }
    if (p != null && p.system == 'switch' && p.scope == 'game' &&
        !p.isState) {
      if (RegExp(r'^profiles/[0-9a-fA-F]{32}/01[0-9a-fA-F]{14}/[0-9a-fA-F]{16}/.+$')
          .hasMatch(p.filePath)) return NeoSyncSaveKind.save;
      // Older scans stripped native provenance. Games may also store actual
      // save data in config/content/cache files. Investigate these names using
      // the local user-save tree; never delete them based on spelling alone.
      if (RegExp(r'^(?:dlc|updates?|contents?|registered|cache|logs?|config|games|system)/',
          caseSensitive: false).hasMatch(p.filePath) ||
          const {'config.json', 'games.json', 'dlc.json', 'updates.json'}
              .contains(leaf)) return NeoSyncSaveKind.unresolved;
      return NeoSyncSaveKind.save;
    }
    if (melonxLocation(key, '/') != null) return NeoSyncSaveKind.save;
    if (playStationComponents.contains(leaf)) return NeoSyncSaveKind.unresolved;
    if (RegExp(r'(?:^|/)(?:dlc|updates|cache|caches|shaders|screenshots|covers|thumbnails|bios|firmware|logs|config|configs)/',
        caseSensitive: false).hasMatch(p?.filePath ?? key)) {
      return NeoSyncSaveKind.foreign;
    }
    // A bare legacy image/config filename may be a flattened savedata file.
    // Only classify it as foreign when a non-bundle canonical origin is known.
    if (p != null && p.system != 'ps3' && !const {'psp', 'pspminis'}.contains(p.system) &&
        RegExp(r'\.(?:png|jpg|jpeg|webp|mp4|cfg|ini|log|tmp)$',
        caseSensitive: false).hasMatch(leaf)) return NeoSyncSaveKind.foreign;
    // Canonical RetroArch objects were emitted from its configured save root;
    // cores may use .bin, .dat or extensionless payloads. The source gate above
    // protects new writes; a second extension whitelist must not break restore.
    if (p != null && p.emulatorSlug.startsWith('retroarch.')) {
      return NeoSyncSaveKind.save;
    }
    return NeoSyncSaveKind.unresolved;
  }

  static bool allowsUpload(String sourcePath, String cloudPath, {
    NeoSyncSaveSource? source,
  }) {
    if (source != null) return source.matches(sourcePath, cloudPath);
    final p = canonical(cloudPath);
    if (p?.system == 'switch' && p?.emulatorSlug == 'melonx') {
      // No trust in the claimed v2/saves namespace: prove the LOCAL origin too.
      final location = melonxLocation(sourcePath, '/');
      return p != null && p.scope == 'game' && !p.isState &&
          location != null && location.internalPath == p.filePath &&
          classify(cloudPath) != NeoSyncSaveKind.foreign;
    }
    if (p != null && p.emulatorSlug.startsWith('retroarch.') &&
        !_standaloneSave(unwrap(p.filePath).split('/').last) &&
        !RegExp(r'^vmu_save[^/]*\.bin$', caseSensitive: false)
            .hasMatch(unwrap(p.filePath).split('/').last) &&
        classify(sourcePath) != NeoSyncSaveKind.save) return false;
    return classify(cloudPath) == NeoSyncSaveKind.save &&
        classify(sourcePath) != NeoSyncSaveKind.foreign;
  }
}

/// The root comes from the emulator's configuration/bookmark, never the game's
/// ROM directory. A resolved source binds that root to one native save member.
enum NeoSyncSaveFamily { retroArchSaves, retroArchStates, retroArchFlycastSystem, armsx2, rpcs3, melonx }

class NeoSyncSaveSource {
  NeoSyncSaveSource._(this.sourcePath, this.rootPath, this.family,
      this.relativePath, this.isState);

  final String sourcePath;
  final String rootPath;
  final NeoSyncSaveFamily family;
  final String relativePath;
  final bool isState;

  static NeoSyncSaveSource? resolve({
    required String filePath,
    required String rootPath,
    required NeoSyncSaveFamily family,
  }) {
    final file = filePath.replaceAll('\\', '/');
    final root = rootPath.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    if (root.isEmpty || !file.startsWith('$root/') ||
        !NeoSyncSavePolicy.safe(file.substring(root.length + 1))) return null;
    final relative = file.substring(root.length + 1);
    if (NeoSyncSavePolicy._hostJunk(relative)) return null;
    // A selected native root cannot authorize a link escaping that root.
    var parent = path.posix.dirname(file);
    while (parent.length >= root.length) {
      if (FileSystemEntity.typeSync(parent, followLinks: false) ==
          FileSystemEntityType.link) return null;
      if (parent == root) break;
      final next = path.posix.dirname(parent);
      if (next == parent) break;
      parent = next;
    }
    var native = relative;
    var isState = family == NeoSyncSaveFamily.retroArchStates;
    switch (family) {
      case NeoSyncSaveFamily.retroArchFlycastSystem:
        if (!RegExp(r'^vmu_save_[A-D][12]\.bin$', caseSensitive: false)
            .hasMatch(relative)) return null;
        native = 'system/dc/$relative';
        break;
      case NeoSyncSaveFamily.rpcs3:
        final m = RegExp(r'(?:^|/)dev_hdd0/home/([0-9]{8})/savedata/([^/]+/.+)$')
            .firstMatch(file);
        if (m == null) return null;
        native = '${m[1]}/${m[2]}';
        break;
      case NeoSyncSaveFamily.melonx:
        final location = NeoSyncSavePolicy.melonxSaveLocation(file, root);
        if (location == null) return null;
        native = location.cloudFilePath;
        break;
      case NeoSyncSaveFamily.armsx2:
        const categories = ['memcards', 'savestates', 'sstates'];
        final rootName = path.posix.basename(root).toLowerCase();
        native = categories.contains(rootName) ? '$rootName/$relative' : relative;
        final parts = native.split('/');
        if (parts.length < 2 || !categories.contains(parts.first.toLowerCase())) {
          return null;
        }
        isState = parts.first.toLowerCase() != 'memcards';
        if (NeoSyncSavePolicy._package(relative)) return null;
        // Folder memory cards contain game-specific files (including icon.sys).
        if (parts.length == 2 && !NeoSyncSavePolicy._standaloneSave(parts.last)) {
          return null;
        }
        if (isState && !NeoSyncSavePolicy._standaloneSave(parts.last)) return null;
        break;
      case NeoSyncSaveFamily.retroArchSaves:
      case NeoSyncSaveFamily.retroArchStates:
        if (NeoSyncSavePolicy._package(relative)) return null;
        final pspBundle = RegExp(r'(?:^|/)(?:PSP/)?SAVEDATA/[^/]+/.+$',
            caseSensitive: false).hasMatch(relative);
        final nativePsp = relative.split('/').map((s) => s.toLowerCase()).toList();
        // PPSSPP places DLC, textures and shader cache alongside SAVEDATA
        // beneath RetroArch's save root. The root alone cannot bless those.
        final pspIndex = nativePsp.indexOf('psp');
        if ((pspIndex >= 0 || path.posix.basename(root).toLowerCase() == 'psp') &&
            !pspBundle) return null;
        // Saves roots are authoritative for core-specific SRAM/RTC/NVRAM and
        // directory cards. Exclude emulator media and state preview sidecars.
        if (!pspBundle && (RegExp(r'\.(?:png|jpg|jpeg|webp|mp4|cfg|ini|log|tmp|bsv|cht|opt|lpl)$',
                caseSensitive: false).hasMatch(relative) ||
            RegExp(r'(?:^|/)(?:screenshots|thumbnails|shaders|bios|firmware|logs|cheats|playlists)/',
                caseSensitive: false).hasMatch(relative))) return null;
        if (isState && !NeoSyncSavePolicy._standaloneSave(relative.split('/').last)) {
          return null;
        }
        break;
    }
    return NeoSyncSaveSource._(file, root, family, native, isState);
  }

  bool matches(String filePath, String cloudPath) {
    if (filePath.replaceAll('\\', '/') != sourcePath) return false;
    final parsed = NeoSyncSavePolicy.canonical(cloudPath);
    if (parsed == null || parsed.isState != isState) return false;
    final remote = NeoSyncSavePolicy.unwrap(parsed.filePath);
    switch (family) {
      case NeoSyncSaveFamily.retroArchFlycastSystem:
        return parsed.system == 'dc' && parsed.emulatorSlug == 'retroarch.flycast' &&
            parsed.scope == 'shared' && remote == relativePath;
      case NeoSyncSaveFamily.rpcs3:
        return parsed.system == 'ps3' && parsed.emulatorSlug == 'rpcs3' &&
            parsed.scope == 'game' && remote == relativePath;
      case NeoSyncSaveFamily.melonx:
        return parsed.system == 'switch' && parsed.emulatorSlug == 'melonx' &&
            parsed.scope == 'game' && remote == relativePath;
      case NeoSyncSaveFamily.armsx2:
        return parsed.system == 'ps2' && parsed.emulatorSlug == 'armsx2' &&
            remote == relativePath;
      case NeoSyncSaveFamily.retroArchSaves:
      case NeoSyncSaveFamily.retroArchStates:
        if (!parsed.emulatorSlug.startsWith('retroarch.')) return false;
        if (remote == relativePath) return true;
        final parts = relativePath.split('/');
        return parts.length > 1 &&
            CloudPathBuilder.retroArchCoreSlug(parts.first) == parsed.emulatorSlug &&
            remote == parts.skip(1).join('/');
    }
  }
}

/// A committed native Switch save. SaveDataId is an opaque container identity,
/// never a Title ID. The identity is read from the emulator's own ExtraData0.
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
