import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cloud save app entry has one folder provider and no server endpoints', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('ICloudSaveProvider()'));
    expect(main, contains('SyncManager.instance.register(cloudSavesProvider)'));
    for (final removed in ['AuthService()', 'BillingService()', 'NotificationService()']) {
      expect(main, isNot(contains(removed)));
    }
  });
}
