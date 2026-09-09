import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RPCS3 keeps Core loading behind the Universal JIT gate', () {
    final bridge = File(
      'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart',
    ).readAsStringSync();

    expect(bridge, isNot(contains('DynamicLibrary.open')));
    expect(bridge, isNot(contains('preloadCoreImage')));
    expect(bridge, contains("invokeMapMethod<String, dynamic>('prepareJit'"));
    expect(bridge, contains("'expandedJitRegion': expandedJitRegion"));
    expect(bridge, contains('bool expandedJitRegion = false'));
  });

  test('Dolphin game deletion refreshes only its private playlist', () {
    final manage = File(
      'lib/screens/game_screen/game_settings_dialog/game_settings_manage_tab.dart',
    ).readAsStringSync();

    expect(manage, contains('DolphinInternalV2Service.isDolphinSystem'));
    expect(manage, contains('GameRepository.deleteGame('));
    expect(manage, contains('refreshDolphinInternalLibrary(_targetSystemFolder)'));
    expect(manage, contains('if (mounted && deleted)'));

    final deleteStart = manage.indexOf('Future<void> _deleteGame()');
    final buildStart = manage.indexOf('@override\n  Widget build', deleteStart);
    expect(deleteStart, greaterThanOrEqualTo(0));
    expect(buildStart, greaterThan(deleteStart));
    final deleteFlow = manage.substring(deleteStart, buildStart);

    expect(
      deleteFlow.indexOf('GameRepository.deleteGame('),
      lessThan(deleteFlow.indexOf('refreshDolphinInternalLibrary')),
    );
  });
}
