import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/pairing_file_service.dart';

void main() {
  const remoteKeys = '''
    <key>identifier</key><string>neostation-test-host</string>
    <key>public_key</key><data>AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=</data>
    <key>private_key</key><data>AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=</data>
  ''';

  List<int> plist(String entries) => utf8.encode('''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>$entries</dict></plist>
  '''.trimLeft());

  test('accepts the Remote Pairing credentials consumed by StikJIT', () {
    expect(
      PairingFileService.inspectData(plist(remoteKeys)),
      PairingFileValidation.validRemotePairing,
    );
  });

  test('accepts an iLoader hybrid file with Remote Pairing credentials', () {
    final hybrid = plist('''
      <key>UDID</key><string>00008150-TEST</string>
      <key>HostID</key><string>legacy-host</string>
      $remoteKeys
    ''');
    expect(
      PairingFileService.inspectData(hybrid),
      PairingFileValidation.validRemotePairing,
    );
  });

  test('rejects a Lockdown-only file with an actionable classification', () {
    final lockdown = plist('''
      <key>UDID</key><string>00008150-TEST</string>
      <key>HostID</key><string>legacy-host</string>
      <key>SystemBUID</key><string>legacy-system</string>
      <key>HostCertificate</key><data>AA==</data>
    ''');
    expect(
      PairingFileService.inspectData(lockdown),
      PairingFileValidation.missingRemotePairingCredentials,
    );
  });

  test('rejects malformed credentials even when the file is large enough', () {
    final invalid = plist('''
      <key>identifier</key><string>neostation-test-host</string>
      <key>public_key</key><data>AA==</data>
      <key>private_key</key><data>not-base64</data>
      <key>padding</key><string>${List<String>.filled(256, 'x').join()}</string>
    ''');
    expect(
      PairingFileService.inspectData(invalid),
      PairingFileValidation.invalid,
    );
  });

  test('recognizes Remote Pairing keys in a binary plist payload', () {
    final binaryFixture = <int>[
      ...ascii.encode('bplist00'),
      ...ascii.encode('identifier'),
      ...ascii.encode('public_key'),
      ...ascii.encode('private_key'),
      ...List<int>.filled(128, 0),
    ];
    expect(
      PairingFileService.inspectData(binaryFixture),
      PairingFileValidation.validRemotePairing,
    );
  });
}
