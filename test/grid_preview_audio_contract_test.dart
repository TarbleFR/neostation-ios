import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('list to grid transition tears down the primary preview', () {
    final host = File(
      'lib/screens/game_screen/my_games_list.dart',
    ).readAsStringSync();

    expect(host, contains('final previousGameViewMode = _lastGameViewMode;'));
    expect(host, contains('if (previousGameViewMode != null)'));
    expect(host, contains('_resetVideoState();'));
  });

  test('grid preview audio is muted on both displays', () {
    final media = File(
      'lib/screens/game_screen/my_games_list/secondary_display.dart',
    ).readAsStringSync();
    final secondary = File(
      'lib/screens/secondary_screen/secondary_screen.dart',
    ).readAsStringSync();

    expect(
      media,
      contains("config.videoSound && config.gameViewMode != 'grid'"),
    );
    expect(media, contains('!_previewAudioEnabled(configProvider!.config)'));
    expect(media, contains("config.gameViewMode == 'grid'"));
    expect(secondary, contains('state.isVideoMuted ? 0.0 : 1.0'));
  });

  test('NeoStation locale is forwarded to the native RPCS3 menu', () {
    final launch = File(
      'lib/services/game/game_launch_service.dart',
    ).readAsStringSync();
    final bridge = File(
      'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart',
    ).readAsStringSync();

    expect(launch, contains('Localizations.localeOf(context).toLanguageTag()'));
    expect(bridge, contains('required String uiLocale'));
    expect(bridge, contains("'uiLocale': uiLocale"));
  });
}
