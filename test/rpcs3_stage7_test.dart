import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/game_model.dart';

void main() {
  test('existing synthetic RPCS3 metadata resolves to PARAM.SFO title', () {
    final resolved = GameModel.resolveDatabaseNamesForDisplay(
      DatabaseGameModel(
        filename: 'BLES00412',
        romPath: 'rpcs3-library://game?title-id=BLES00412',
        titleId: 'BLES00412',
        titleName: 'The Lord of the Rings: Conquest™',
        realName: 'BLES00412',
        screenscraperRealName: 'BLES00412',
      ),
    );
    expect(resolved.displayName, 'The Lord of the Rings: Conquest™');
    expect(resolved.realName, 'The Lord of the Rings: Conquest™');
    expect(resolved.hasMeaningfulScrapedName, isFalse);
  });

  test('RPCS3 launch bypasses the standalone Start screen', () {
    final service = File(
      'lib/services/rpcs3_launch_service.dart',
    ).readAsStringSync();
    final plugin = File(
      'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
    ).readAsStringSync();
    expect(service, contains('Rpcs3InternalService.launchTitle'));
    expect(service, isNot(contains('openJitRequest')));
    expect(plugin, contains('@"launchGame"'));
    expect(plugin, contains('self->_api.boot_game'));
  });
}
