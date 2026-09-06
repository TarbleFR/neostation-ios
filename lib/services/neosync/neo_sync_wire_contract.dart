import '../../utils/cloud_path_builder.dart';

/// NeoSync's September 2026 API stores a native relative `file_path` and an
/// explicit `type`; the app's v2 envelope is a local routing identity only.
/// Contract: misobadev/neostation-frontend commit 11d3f7fdd127910e45a1b2759b96a02581ee6ae6.
class NeoSyncWireIdentity {
  const NeoSyncWireIdentity._(this.filePath, this.type, this.system,
      this.emulator, this.scope);

  final String filePath;
  final String type;
  final String? system;
  final String? emulator;
  final String scope;

  factory NeoSyncWireIdentity.fromCloudKey(String key, {
    String? system,
    String? emulator,
    bool? isState,
    String? scope,
    String? nativeRelativePath,
  }) {
    final normalized = key.replaceAll('\\', '/');
    final parsed = CloudPathBuilder.parse(normalized);
    var relative = normalized;
    final effectiveSystem = parsed?.system ?? system;
    final effectiveEmulator = parsed?.emulatorSlug ?? emulator;
    final effectiveScope = parsed?.scope ?? scope ?? 'game';
    final state = parsed?.isState ?? isState ?? normalized.startsWith('states/');
    if (parsed != null) {
      relative = parsed.filePath;
      // Dolphin snapshots are versioned containers rather than native leaf
      // files. Their native title ID is essential: gci-USA-A.nsav and
      // wii-data.nsav are otherwise the same name for every game.
      if (parsed.emulatorSlug == 'dolphinios' && !parsed.isShared) {
        if (parsed.gameName == null || parsed.gameName!.isEmpty) {
          throw const FormatException('Missing Dolphin save identity');
        }
        relative = '${parsed.gameName}/$relative';
      } else if (nativeRelativePath != null) {
        relative = nativeRelativePath.replaceAll('\\', '/');
      }
    } else if (normalized.startsWith('saves/') || normalized.startsWith('states/')) {
      relative = normalized.substring(normalized.indexOf('/') + 1);
    }
    if (!_safeRelative(relative)) {
      throw const FormatException('Unsafe NeoSync native relative path');
    }
    return NeoSyncWireIdentity._(relative, state ? 'state'
        : effectiveScope == 'shared' ? 'shared' : 'save',
        effectiveSystem, effectiveEmulator, effectiveScope);
  }

  static bool _safeRelative(String path) => path.isNotEmpty &&
      !path.contains(':') && !RegExp(r'[\x00-\x1f]').hasMatch(path) &&
      !path.split('/').any((part) => part.isEmpty || part == '.' || part == '..');
}
