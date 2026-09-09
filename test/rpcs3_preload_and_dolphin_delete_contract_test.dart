import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RPCS3 maps its embedded Core before Universal JIT attachment', () {
    final bridge = File(
      'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart',
    ).readAsStringSync();

    expect(bridge, contains('DynamicLibrary.open(corePath)'));
    expect(bridge, contains('RPCS3_IOS_EXPANDED_JIT_ARENA'));
    expect(bridge, contains('Frameworks/libRPCS3Core.dylib'));

    final prepareStart = bridge.indexOf(
      'static Future<Map<String, dynamic>> prepareJit',
    );
    final initializeStart = bridge.indexOf(
      'static Future<Map<String, dynamic>> initialize',
      prepareStart,
    );
    expect(prepareStart, greaterThanOrEqualTo(0));
    expect(initializeStart, greaterThan(prepareStart));

    final prepare = bridge.substring(prepareStart, initializeStart);
    final preloadCall = prepare.indexOf('preloadCoreImage(');
    final helperCall = prepare.indexOf("invokeMapMethod<String, dynamic>('prepareJit'");
    expect(preloadCall, greaterThanOrEqualTo(0));
    expect(helperCall, greaterThan(preloadCall));
    expect(prepare, contains("response['corePreloaded'] = true"));
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
