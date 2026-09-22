import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RPCS3 Dart launch path has no boot watchdog or progress control', () {
    final source = File(
      'lib/services/rpcs3_launch_service.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('Rpcs3BootWatchdog')));
    expect(source, isNot(contains('bootProgress')));
    expect(source, isNot(contains('abortBoot')));
    expect(source, isNot(contains('Rpcs3InternalBridge.stop')));
    expect(
      source,
      contains('return await Rpcs3InternalService.launchTitle('),
    );
  });

  test('RPCS3 launch never starts an automatic second native boot', () {
    final source = File(
      'lib/services/rpcs3_launch_service.dart',
    ).readAsStringSync();

    expect(
      RegExp(r'Rpcs3InternalService\.launchTitle\(')
          .allMatches(source)
          .length,
      1,
    );
  });
}
