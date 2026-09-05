import '../../utils/cloud_path_builder.dart';
import '../dolphin_neosync_store.dart';

enum NeoSyncSaveKind { save, foreign, unresolved }

/// One policy for uploads, restoration and cleanup. A filename alone cannot
/// identify a PlayStation savedata component. Unknown historical objects must
/// be investigated, never silently deleted as if they were proven non-saves.
class NeoSyncSavePolicy {
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
    final file = filePath.replaceAll('\\', '/');
    final base = root.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    if (!file.startsWith('$base/') ||
        !safe(file.replaceFirst(RegExp(r'^/'), ''))) return null;
    // Only the emulator's actual user-save tree is authoritative. In particular
    // a title-ID directory in games, DLC, installed content or caches is not.
    final match = RegExp(
      r'(?:^|/)user/save/0000000000000000/(?:[0-9a-fA-F]{32}/|[0-9a-fA-F]{16}/)?(01[0-9a-fA-F]{14})/(.+)$',
    ).firstMatch(file);
    if (match == null) return null;
    final title = match[1]!;
    if (!title.toLowerCase().endsWith('000')) return null;
    final payload = match[2]!;
    if (_package(payload) || _hostJunk(payload)) return null;
    return (titleId: title, internalPath: payload);
  }

  static bool _package(String value) => RegExp(
    r'\.(?:nca|nsp|nsz|xci|xcz|nro|pkg|rap|rif|iso|cso|chd|gcm|rvz|wbfs|wad|rom|nes|gb|gbc|gba|nds|3ds|cia|elf|dol|exe|dll|dylib|so|ipa)$',
    caseSensitive: false,
  ).hasMatch(value);

  static bool _hostJunk(String value) => value.split('/').any((part) =>
      part.toLowerCase() == '.ds_store' || part.startsWith('._') ||
      part.toLowerCase() == 'thumbs.db' || part == '__MACOSX');

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
    if (p != null && !p.isState && p.system == 'psp' &&
        p.scope == 'game' && p.filePath.split('/').length >= 2 &&
        RegExp(r'^[A-Z]{4}[0-9]{5}').hasMatch(p.filePath)) {
      return NeoSyncSaveKind.save;
    }
    if (_package(key)) return NeoSyncSaveKind.foreign;
    if (DolphinSaveTarget.parse(key) != null) return NeoSyncSaveKind.save;
    if (p?.emulatorSlug == 'dolphinios') return NeoSyncSaveKind.unresolved;
    if (_standaloneSave(leaf) ||
        RegExp(r'^vmu_save[^/]*\.bin$', caseSensitive: false).hasMatch(leaf)) {
      return NeoSyncSaveKind.save;
    }
    if (p != null && p.system == 'switch' && p.scope == 'game' &&
        !p.isState) {
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
    if (p != null && p.system != 'ps3' && p.system != 'psp' &&
        RegExp(r'\.(?:png|jpg|jpeg|webp|mp4|cfg|ini|log|tmp)$',
        caseSensitive: false).hasMatch(leaf)) return NeoSyncSaveKind.foreign;
    return NeoSyncSaveKind.unresolved;
  }

  static bool allowsUpload(String sourcePath, String cloudPath) {
    final p = canonical(cloudPath);
    if (p?.system == 'switch' && p?.emulatorSlug == 'melonx') {
      // No trust in the claimed v2/saves namespace: prove the LOCAL origin too.
      final location = melonxLocation(sourcePath, '/');
      return p != null && p.scope == 'game' && !p.isState &&
          location != null && location.internalPath == p.filePath &&
          classify(cloudPath) != NeoSyncSaveKind.foreign;
    }
    return classify(cloudPath) == NeoSyncSaveKind.save &&
        classify(sourcePath) != NeoSyncSaveKind.foreign;
  }
}
