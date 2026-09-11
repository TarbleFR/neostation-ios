import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Build 243 restores the NeoStation silent-mode policy around RPCS3', () {
    final configure = File(
      'build-utils/configure_rpcs3_ios_v2.py',
    ).readAsStringSync();
    final transitionPatch = File(
      'build-utils/patches/rpcs3_build243_menu_transition.patch',
    ).readAsStringSync();

    expect(configure, contains('preserve_frontend_silent_mode_policy'));
    expect(configure, contains('patch_ios_video_player_audio_session.py'));
    expect(transitionPatch, contains('previousAudioCategory'));
    expect(transitionPatch, contains('AVAudioSessionCategoryAmbient'));
    expect(
      transitionPatch,
      contains('AVAudioSessionCategoryOptionMixWithOthers'),
    );
    expect(
      transitionPatch,
      isNot(contains('setCategory:self.previousAudioCategory')),
    );
    expect(transitionPatch, contains('frontend audio policy restored'));
  });

  test('NeoStation frontend keeps ambient audio ownership on iOS', () {
    final nativePolicy = File(
      'packages/external_folder_access/ios/Classes/ExternalFolderAccessPlugin.swift',
    ).readAsStringSync();

    expect(nativePolicy, contains('.ambient'));
    expect(nativePolicy, contains('.mixWithOthers'));
  });
}
