import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_migration_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FailingMigrationPreferences implements SharedPreferences {
  bool failWrites = false;
  final durable = <String, String>{};
  final cache = <String, String>{};

  @override
  String? getString(String key) => cache[key];

  @override
  Future<bool> setString(String key, String value) async {
    cache[key] = value;
    if (failWrites) return false;
    durable[key] = value;
    return true;
  }

  @override
  Future<void> reload() async {
    cache
      ..clear()
      ..addAll(durable);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fresh setup uses embedded without showing an upgrade offer', () async {
    final service = RetroArchMigrationService(
      preferences: FailingMigrationPreferences(),
    );
    await service.initialize(existingInstallation: false);
    expect(service.usesEmbedded, isTrue);
    expect(await service.shouldOfferMigration(backendAvailable: true), isFalse);
  });

  test('existing setup remains external until explicit decision', () async {
    final service = RetroArchMigrationService(
      preferences: FailingMigrationPreferences(),
    );
    expect(service.usesEmbedded, isFalse);
    await service.load();
    expect(service.usesEmbedded, isFalse);
    await service.initialize(existingInstallation: true);
    expect(service.usesEmbedded, isFalse);
    expect(await service.shouldOfferMigration(backendAvailable: true), isTrue);
  });

  for (final embedded in [true, false]) {
    test(
      '${embedded ? 'acceptance' : 'decline'} persists across relaunch and initialization',
      () async {
        final preferences = FailingMigrationPreferences();
        final first = RetroArchMigrationService(preferences: preferences);
        await first.initialize(existingInstallation: true);
        if (embedded) {
          await first.chooseEmbedded(backendAvailable: true);
        } else {
          await first.keepExternal();
        }
        final relaunched = RetroArchMigrationService(preferences: preferences);
        await relaunched.initialize(existingInstallation: false);
        expect(relaunched.usesEmbedded, embedded);
        expect(relaunched.needsMigration, isFalse);
        expect(relaunched.decisionVersion, 1);
      },
    );
  }

  test(
    'unavailable backend does not consume pending offer or allow opt-in',
    () async {
      final service = RetroArchMigrationService(
        preferences: FailingMigrationPreferences(),
      );
      await service.initialize(existingInstallation: true);
      expect(
        await service.shouldOfferMigration(backendAvailable: false),
        isFalse,
      );
      await expectLater(
        service.chooseEmbedded(backendAvailable: false),
        throwsA(isA<RetroArchMigrationUnavailable>()),
      );
      expect(service.usesEmbedded, isFalse);
      expect(service.needsMigration, isTrue);
    },
  );

  test('failed persistence retains external routing and can retry', () async {
    final preferences = FailingMigrationPreferences();
    final service = RetroArchMigrationService(preferences: preferences);
    await service.initialize(existingInstallation: true);
    preferences.failWrites = true;
    await expectLater(
      service.chooseEmbedded(backendAvailable: true),
      throwsStateError,
    );
    expect(service.usesEmbedded, isFalse);
    expect(service.needsMigration, isTrue);
    final relaunched = RetroArchMigrationService(preferences: preferences);
    await relaunched.load();
    expect(relaunched.usesEmbedded, isFalse);
    preferences.failWrites = false;
    await service.chooseEmbedded(backendAvailable: true);
    expect(service.usesEmbedded, isTrue);
    expect(service.needsMigration, isFalse);
  });

  test('corrupted saved preference never grants embedded consent', () async {
    final preferences = FailingMigrationPreferences();
    preferences.durable[RetroArchMigrationService.preferenceKey] = jsonEncode({
      'schema': 1,
      'mode': 'embedded',
    });
    final service = RetroArchMigrationService(preferences: preferences);
    await service.initialize(existingInstallation: false);
    expect(service.usesEmbedded, isFalse);
    expect(service.needsMigration, isTrue);
  });
}
