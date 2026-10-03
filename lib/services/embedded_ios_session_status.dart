import 'package:flutter/services.dart';

/// Read the presented native session, including pause/menu/teardown. A failed
/// probe is not proof of exit and must never re-enable frontend audio.
abstract final class EmbeddedIOSSessionStatus {
  static const _channels = {
    'ios_dolphin_internal': MethodChannel('neostation/dolphin_internal'),
    'ios_rpcs3_internal': MethodChannel('neostation/rpcs3_internal'),
    'ios_retroarch_internal': MethodChannel('neostation/retroarch_internal'),
  };
  static bool handles(String? name) => _channels.containsKey(name);
  static Future<bool> isActive(String name) async {
    final channel = _channels[name];
    if (channel == null) throw ArgumentError.value(name, 'name');
    try {
      return await channel.invokeMethod<bool>('isSessionActive') != false;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }
}
