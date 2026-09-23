import 'package:flutter/services.dart';

/// DiscIO reads the container without starting an emulator or preparing JIT.
/// Keep the source platform separate from the Ports playlist destination.
class DusklightGameIdentity {
  const DusklightGameIdentity._(this.discId, this.sourceSystem);

  static const title = 'The Legend of Zelda: Twilight Princess';
  static const displayTitle = '$title — Dusklight';
  static const supportedIds = <String>{
    'GZ2E01', 'GZ2J01', 'GZ2P01', 'RZDE01', 'RZDJ01', 'RZDP01',
  };
  static const _channel = MethodChannel('neostation/dolphin_internal');

  final String discId;
  final String sourceSystem;
  int get screenScraperSystemId => sourceSystem == 'wii' ? 16 : 13;

  static DusklightGameIdentity? fromDiscId(String? value) {
    final id = value?.trim().toUpperCase();
    if (id == null || !supportedIds.contains(id)) return null;
    return DusklightGameIdentity._(id, id.startsWith('R') ? 'wii' : 'gc');
  }

  static Future<DusklightGameIdentity?> read(String gamePath) async {
    for (final system in const ['gc', 'wii']) {
      try {
        final data = await _channel.invokeMapMethod<String, dynamic>(
          'saveIdentity', {'gamePath': gamePath, 'system': system},
        );
        final identity = fromDiscId(data?['gameId']?.toString());
        if (identity != null && data?['system'] == identity.sourceSystem &&
            identity.sourceSystem == system) return identity;
      } on PlatformException {
        // Try the other source platform; never infer a title from the filename.
      } on MissingPluginException {
        return null;
      }
    }
    return null;
  }
}
