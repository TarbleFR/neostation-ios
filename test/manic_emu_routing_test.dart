import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/game/game_launch_service.dart';
import 'package:neostation/services/ios_emulator_preference_service.dart';

void main() {
  test('an explicit Manic EMU choice does not depend on a linked folder', () {
    expect(
      GameLaunchService.shouldAttemptManicDirectLaunch(
        IosLibraryEmulator.manicEmu,
        installed: true,
      ),
      isTrue,
    );
  });

  test('RetroArch choice never enters the Manic direct-launch path', () {
    expect(
      GameLaunchService.shouldAttemptManicDirectLaunch(
        IosLibraryEmulator.retroArch,
        installed: true,
      ),
      isFalse,
    );
  });
}
