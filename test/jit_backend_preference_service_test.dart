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

  test('ARMSX2 Standard is the default and Direct is explicit', () async {
    expect(
      await JitBackendPreferenceService.useArmsx2DirectLaunch(),
      isFalse,
    );

    await JitBackendPreferenceService.setUseArmsx2DirectLaunch(true);
    expect(
      await JitBackendPreferenceService.useArmsx2DirectLaunch(),
      isTrue,
    );

    await JitBackendPreferenceService.setUseArmsx2DirectLaunch(false);
    expect(
      await JitBackendPreferenceService.useArmsx2DirectLaunch(),
      isFalse,
    );
  });

  test('ARMSX2 uses a fresh v2 key so old experiments cannot enable Direct', () async {
    SharedPreferences.setMockInitialValues({
      'ios_armsx2_autoload_last_game_v1': true,
    });

    expect(
      await JitBackendPreferenceService.useArmsx2DirectLaunch(),
      isFalse,
    );

    final preferences = File(
      'lib/services/jit_backend_preference_service.dart',
    ).readAsStringSync();
    expect(preferences, contains('ios_armsx2_direct_load_last_game_v2'));
    expect(preferences, isNot(contains("getBool('ios_armsx2_autoload_last_game_v1')")));
  });

  test('Tools exposes Pairing, JIT fallback, and explicit ARMSX2 mode', () {
    final tools = File(
      'lib/screens/settings_screen/new_settings_options/'
      'tools_settings_content.dart',
    ).readAsStringSync();

    expect(tools, contains('int getItemCount() => 3;'));
    expect(tools, contains('JitFallbackLocale.title'));
    expect(tools, contains('Armsx2JitModeLocale.title'));
    expect(tools, contains('useArmsx2DirectLaunch'));
    expect(tools, contains('setUseArmsx2DirectLaunch'));
    expect(tools, contains('CustomToggleSwitch'));
  });
}
