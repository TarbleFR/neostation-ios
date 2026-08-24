/// Builds and parses the canonical NeoSync cloud paths.
///
/// Format (applies to both saves and states), always under the `v2/` namespace
/// so it can never collide with legacy v1 paths (`saves/...`):
///   `v2/saves/<system>/<emulator-slug>/<scope>/[<game>/]<file>`
///   `v2/states/<system>/<emulator-slug>/<scope>/[<game>/]<file>`
class CloudPathBuilder {
  CloudPathBuilder._();

  static const namespaceV2 = 'v2';
  static const rootSave = 'saves';
  static const rootState = 'states';

  static bool isLegacy(String cloudPath) {
    return !cloudPath.startsWith('$namespaceV2/');
  }

  static String build({
    required String system,
    required String emulatorSlug,
    required String scope,
    required String filePath,
    String? gameName,
    bool isState = false,
  }) {
    final root = isState ? rootState : rootSave;
    final segments = <String>[namespaceV2, root, system, emulatorSlug, scope];
    if (scope == 'game' && gameName != null && gameName.isNotEmpty) {
      segments.add(sanitizeGameName(gameName));
    }
    segments.add(filePath);
    return segments.join('/').replaceAll('\\', '/');
  }

  static ParsedCloudPath? parse(String cloudPath) {
    final isState = cloudPath.startsWith('$namespaceV2/$rootState/');
    if (!isState && !cloudPath.startsWith('$namespaceV2/$rootSave/')) {
      return null;
    }

    final segments = cloudPath.split('/');
    if (segments.length < 6) return null;

    final system = segments[2];
    final emulatorSlug = segments[3];
    final scope = segments[4];
    if (scope != 'shared' && scope != 'game') return null;

    final rest = segments.sublist(5);
    final String filePath;
    final String? gameName;
    if (scope == 'game' && rest.length >= 2) {
      gameName = rest.first;
      filePath = rest.sublist(1).join('/');
    } else {
      gameName = null;
      filePath = rest.join('/');
    }

    return ParsedCloudPath(
      isState: isState,
      system: system,
      emulatorSlug: emulatorSlug,
      scope: scope,
      gameName: gameName,
      filePath: filePath,
    );
  }

  static String sanitizeGameName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  }

  static String retroArchCoreSlug(String coreNameOrIdentifier) {
    var input = coreNameOrIdentifier.trim();
    final extMatch = RegExp(r'\.(dll|so|dylib|appimage|exe|bin)$')
        .firstMatch(input.toLowerCase());
    if (extMatch != null) {
      input = input.substring(0, extMatch.start);
    }
    final core = input
        .replaceAll('_libretro', '')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll('_', '-')
        .replaceAll(RegExp(r'[^a-z0-9.\-]'), '');
    return 'retroarch.$core';
  }

  static String standaloneSlugFromUniqueId(String uniqueId) {
    final parts = uniqueId.split('.');
    if (parts.isEmpty) return 'standalone';
    final last = parts.last.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9\-]'),
      '',
    );
    return last.isEmpty ? 'standalone' : last;
  }

  static String slugFromEmulatorUniqueId(String uniqueId) {
    final lower = uniqueId.toLowerCase();
    if (lower.contains('.ra64.')) {
      return retroArchCoreSlug(uniqueId.split('.ra64.').last);
    }
    if (lower.contains('.ra32.')) {
      return retroArchCoreSlug(uniqueId.split('.ra32.').last);
    }
    if (lower.contains('.ra.')) {
      return retroArchCoreSlug(uniqueId.split('.ra.').last);
    }
    return standaloneSlugFromUniqueId(uniqueId);
  }
}

class ParsedCloudPath {
  final bool isState;
  final String system;
  final String emulatorSlug;
  final String scope;
  final String? gameName;
  final String filePath;

  const ParsedCloudPath({
    required this.isState,
    required this.system,
    required this.emulatorSlug,
    required this.scope,
    this.gameName,
    required this.filePath,
  });

  bool get isShared => scope == 'shared';
}
