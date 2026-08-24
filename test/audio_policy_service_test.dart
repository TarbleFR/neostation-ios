import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audio policy is lifecycle-only', () {
    final policy = File(
      'lib/services/audio_policy_service.dart',
    ).readAsStringSync();

    expect(policy, contains('restoreAfterSharedAudioEngineInitialization'));
    expect(policy, contains("reason: 'application-start'"));
    expect(policy, contains("reason: 'application-resumed'"));
    expect(policy, isNot(contains('prepareForPlayback')));
    expect(policy, isNot(contains('afterPlaybackStarted')));
    expect(policy, isNot(contains('setVideoPlaybackActive')));
  });

  test('SFX uses the official direct-playback model', () {
    final source = File('lib/services/sfx_service.dart').readAsStringSync();

    expect(source, contains('SoLoud.instance.play(source, volume: _volume);'));
    expect(source, contains('restoreAfterSharedAudioEngineInitialization'));
    expect(source, isNot(contains('_sfxStartSerial')));
    expect(source, isNot(contains('paused: true')));
    expect(source, isNot(contains('setPause(handle, false)')));
    expect(source, isNot(contains('prepareForPlayback')));
    expect(source, isNot(contains('afterPlaybackStarted')));
  });

  test('playback clients never arbitrate AVAudioSession', () {
    for (final file in <String>[
      'lib/services/home_music_service.dart',
      'lib/screens/game_screen/my_games_list/secondary_display.dart',
      'lib/screens/game_screen/game_details_card/'
          'game_details_card_list.dart',
      'lib/screens/secondary_screen/secondary_screen.dart',
      'lib/widgets/shaders/shader_gif_widget.dart',
    ]) {
      final source = File(file).readAsStringSync();
      expect(source, isNot(contains('AudioPolicyService')), reason: file);
      expect(source, isNot(contains('mixWithOthers: true')), reason: file);
    }

    final music = File(
      'lib/services/music_player_service.dart',
    ).readAsStringSync();
    expect(music, contains('restoreAfterSharedAudioEngineInitialization'));
    expect(music, isNot(contains('prepareForPlayback')));
    expect(music, isNot(contains('afterPlaybackStarted')));
    expect(music, isNot(contains('ensureSilentCompatibleSession')));
  });

  test('preview lifecycle protections are preserved', () {
    final host = File(
      'lib/screens/game_screen/my_games_list.dart',
    ).readAsStringSync();
    final source = File(
      'lib/screens/game_screen/my_games_list/'
      'secondary_display.dart',
    ).readAsStringSync();

    expect(host, contains('Duration(seconds: 2)'));
    expect(source, contains('_videoGeneration'));
    expect(source, contains('_videoTransition'));
    expect(source, contains('_fadeVideoVolume'));
    expect(source, contains('_disposeVideoController'));
  });

  test('iOS video plugin cannot claim the shared session', () {
    final patch = File(
      'build-utils/patch_ios_video_player_audio_session.py',
    ).readAsStringSync();
    final codemagic = File('codemagic.yaml').readAsStringSync();
    final native = File(
      'packages/external_folder_access/ios/Classes/'
      'ExternalFolderAccessPlugin.swift',
    ).readAsStringSync();

    expect(patch, contains('NEOSTATION_AUDIO_SESSION_OWNED_EXTERNALLY'));
    expect(patch, contains('requestedCategory: .playback'));
    expect(codemagic, contains('patch_ios_video_player_audio_session.py'));
    expect(native, contains('AVAudioSession.interruptionNotification'));
    expect(native, contains('AVAudioSession.routeChangeNotification'));
    expect(native, contains('session.category != .ambient'));
  });
}
