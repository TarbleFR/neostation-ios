import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Theme commits menu visibility before audio initialization', () {
    final homeMusic = File(
      'lib/services/home_music_service.dart',
    ).readAsStringSync();
    final assignment = homeMusic.indexOf('_mainMenuActive = value;');
    final initialization = homeMusic.indexOf('if (!_initialized)', assignment);

    expect(assignment, greaterThanOrEqualTo(0));
    expect(initialization, greaterThan(assignment));
    expect(homeMusic, contains('await SfxService().init();'));
    expect(homeMusic, contains('SoLoud.instance.play('));
    expect(homeMusic, isNot(contains('AudioPolicyService')));
    expect(homeMusic, isNot(contains('prepareForPlayback')));
    expect(homeMusic, isNot(contains('afterPlaybackStarted')));

    final themeSettings = File(
      'lib/screens/settings_screen/new_settings_options/'
      'themes_settings_content.dart',
    ).readAsStringSync();
    expect(themeSettings, contains('homeMusic.setMainMenuActive(false)'));

    final sfx = File('lib/services/sfx_service.dart').readAsStringSync();
    expect(sfx, contains('SoLoud.instance.play(source, volume: _volume);'));
    expect(sfx, isNot(contains('_sfxStartSerial')));
  });
}
