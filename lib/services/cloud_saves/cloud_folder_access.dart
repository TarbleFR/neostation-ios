import 'dart:io';
import 'package:flutter/services.dart';

/// Native broker owns security scopes, coordination and iCloud availability.
/// A path string alone is never treated as permission to use a cloud folder.
abstract class CloudFolderAccess {
  void Function()? onAvailabilityChanged;
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> arguments = const {}]);
}

class IOSCloudFolderAccess extends CloudFolderAccess {
  static const channel = MethodChannel('neostation/icloud_saves');
  IOSCloudFolderAccess() {
    if (Platform.isIOS) {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'availabilityChanged') onAvailabilityChanged?.call();
      });
    }
  }
  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> arguments = const {}]) async {
    if (!Platform.isIOS) {
      if (method == 'status' || method == 'recoverRestores') return {'connected': false, 'enabled': false};
      throw PlatformException(code: 'UNAVAILABLE', message: 'iCloud Drive requires iOS.');
    }
    final result = await channel.invokeMapMethod<String, dynamic>(method, arguments);
    return result ?? <String, dynamic>{};
  }
}
