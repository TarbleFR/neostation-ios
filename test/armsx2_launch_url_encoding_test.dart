import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ARMSX2 physical launch never reconstructs a custom URL', () {
    final source = File(
      'lib/services/armsx2_library_service.dart',
    ).readAsStringSync();
    expect(source, contains('StikJitArmsx2Service.launch'));
    expect(source, contains('path.normalize(romPath)'));
    expect(source, isNot(contains("armsx2://launch?game=")));
    expect(source, isNot(contains('Uri.encodeComponent')));
    expect(source, isNot(contains('IosShortcutJitLaunchService')));
  });
}
