import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RPCS3 restores the NeoStation silent-mode policy when it stops', () {
    final configure = File(
      'build-utils/configure_rpcs3_ios_v2.py',
    ).readAsStringSync();
    // The Build 243 transition patch was folded into the bridge source and
    // removed as an unused file; check the bridge itself.
    final bridge = File(
      'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
    ).readAsStringSync();

    expect(configure, contains('preserve_frontend_silent_mode_policy'));
    expect(configure, contains('patch_ios_video_player_audio_session.py'));
    expect(bridge, contains('previousAudioCategory'));
    expect(bridge, contains('AVAudioSessionCategoryAmbient'));
    expect(bridge, contains('AVAudioSessionCategoryOptionMixWithOthers'));
    expect(bridge, isNot(contains('setCategory:self.previousAudioCategory')));
    expect(bridge, contains('frontend audio policy restored'));
  });

  test('NeoStation frontend keeps ambient audio ownership on iOS', () {
    final nativePolicy = File(
      'packages/external_folder_access/ios/Classes/ExternalFolderAccessPlugin.swift',
    ).readAsStringSync();

    expect(nativePolicy, contains('.ambient'));
    expect(nativePolicy, contains('.mixWithOthers'));
  });
}
