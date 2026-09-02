import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/jit_backend_preference_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('global JIT fallback defaults to integrated StikJIT', () async {
    expect(
      await JitBackendPreferenceService.useStikDebugFallback(),
      isFalse,
    );
  });

  test('global JIT fallback persists both backend choices', () async {
    await JitBackendPreferenceService.setUseStikDebugFallback(true);
    expect(
      await JitBackendPreferenceService.useStikDebugFallback(),
      isTrue,
    );

    await JitBackendPreferenceService.setUseStikDebugFallback(false);
    expect(
      await JitBackendPreferenceService.useStikDebugFallback(),
      isFalse,
    );
  });

  test('one preference gates both integrated emulator paths', () {
    final launcher = File(
      'lib/services/ios_shortcut_jit_launch_service.dart',
    ).readAsStringSync();

    expect(
      launcher,
      contains('JitBackendPreferenceService.useStikDebugFallback()'),
    );
    expect(
      RegExp(r'!useStikDebugFallback\s*&&\s*shortcutName == melonxShortcutName')
          .hasMatch(launcher),
      isTrue,
    );
    expect(
      RegExp(r'!useStikDebugFallback\s*&&\s*shortcutName == armsx2ShortcutName')
          .hasMatch(launcher),
      isTrue,
    );
    expect(launcher, contains('final shortcutUri = buildRunUri'));
  });

  test('Tools exposes only Pairing File and global JIT fallback', () {
    final tools = File(
      'lib/screens/settings_screen/new_settings_options/'
      'tools_settings_content.dart',
    ).readAsStringSync();

    expect(tools, contains('int getItemCount() => 2;'));
    expect(tools, contains('JitFallbackLocale.title'));
    expect(tools, contains('CustomToggleSwitch'));
    expect(tools, contains('setUseStikDebugFallback'));
    expect(tools, isNot(contains('Armsx2JitModeLocale')));
    expect(tools, isNot(contains('setUseArmsx2AutoLoadLastGame')));
  });

  test('ARMSX2 launch mode is not persisted by NeoStation', () async {
    expect(
      await JitBackendPreferenceService.useArmsx2AutoLoadLastGame(),
      isFalse,
    );

    await JitBackendPreferenceService.setUseArmsx2AutoLoadLastGame(true);
    expect(
      await JitBackendPreferenceService.useArmsx2AutoLoadLastGame(),
      isFalse,
    );

    final preferences = File(
      'lib/services/jit_backend_preference_service.dart',
    ).readAsStringSync();
    expect(preferences, isNot(contains('ios_armsx2_autoload_last_game_v1')));
    expect(preferences, contains('ARMSX2 itself is the sole source'));
  });
}
