import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iCloud activation uses hardened native broker and creates save roots', () {
    final package = File('packages/external_folder_access/pubspec.yaml').readAsStringSync();
    final bootstrap = File('packages/external_folder_access/ios/Classes/ExternalFolderAccessPluginBootstrap.swift').readAsStringSync();
    final native = File('packages/external_folder_access/ios/Classes/ICloudFolderPluginV2.swift').readAsStringSync();
    final dart = File('lib/services/cloud_saves/cloud_folder_access.dart').readAsStringSync();

    expect(package, contains('pluginClass: ExternalFolderAccessPluginBootstrap'));
    expect(bootstrap, contains('ExternalFolderAccessPlugin.register'));
    expect(bootstrap, contains('ICloudFolderPluginV2.register'));
    expect(dart, contains("MethodChannel('neostation/icloud_saves_v2')"));

    for (final invariant in <String>[
      'ubiquityIdentityToken',
      'UIDocumentPickerViewController',
      'NSFileCoordinator()',
      'NeoStation/Saves',
      'DolphiniOS/GameCube',
      'DolphiniOS/Wii',
      'ARMSX2/PS2',
      'MeloNX/Switch',
      'RPCS3/PS3',
      'RetroArch',
      'startAccessingSecurityScopedResource()',
      'PRESENTATION_FAILED',
    ]) {
      expect(native, contains(invariant), reason: 'missing activation invariant: $invariant');
    }
  });
}
