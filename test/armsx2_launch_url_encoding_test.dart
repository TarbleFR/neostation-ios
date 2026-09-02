import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('linked ARMSX2 physical launch percent-encodes spaces, never pluses', () {
    final source = File(
      'lib/services/armsx2_library_service.dart',
    ).readAsStringSync();

    expect(source, contains('Uri.encodeComponent(fileName)'));
    expect(source, contains("Uri.parse('armsx2://launch?game=\$encodedFileName')"));
    expect(source, isNot(contains("queryParameters: {'game': fileName}")));

    final encoded = Uri.encodeComponent(
      'Dragon Ball Z - Budokai 2 (Europe) (En,Fr,De,Es,It).iso',
    );
    expect(encoded, contains('%20'));
    expect(encoded, isNot(contains('+')));
  });
}
