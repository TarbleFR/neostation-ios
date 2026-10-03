import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/tools_settings_content.dart';
import 'package:neostation/services/jit_backend_preference_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('global JIT fallback defaults to integrated StikJIT', () async {
    expect(await JitBackendPreferenceService.useStikDebugFallback(), isFalse);
  });

  test('global JIT fallback persists both backend choices', () async {
    await JitBackendPreferenceService.setUseStikDebugFallback(true);
    expect(await JitBackendPreferenceService.useStikDebugFallback(), isTrue);

    await JitBackendPreferenceService.setUseStikDebugFallback(false);
    expect(await JitBackendPreferenceService.useStikDebugFallback(), isFalse);
  });

  test('global fallback remains scoped to the legacy MeloNX shortcut path', () {
    final launcher = File(
      'lib/services/ios_shortcut_jit_launch_service.dart',
    ).readAsStringSync();

    expect(
      launcher,
      contains('JitBackendPreferenceService.useStikDebugFallback()'),
    );
    expect(
      RegExp(
        r'!useStikDebugFallback\s*&&\s*shortcutName == melonxShortcutName',
      ).hasMatch(launcher),
      isTrue,
    );
    expect(launcher, isNot(contains('armsx2ShortcutName')));
    expect(launcher, isNot(contains('StikJitArmsx2Service')));
    expect(launcher, contains('final shortcutUri = buildRunUri'));
  });

  test(
    'Tools retains three controller entries after moving screen sharing to the main menu',
    () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        final state =
            const ToolsSettingsContent(
                  isContentFocused: true,
                  selectedContentIndex: 0,
                ).createState()
                as ToolsSettingsContentState;

        expect(
          state.getItemCount(),
          3,
          reason:
              'Controller navigation must match the visible tools on $platform',
        );
      }
    },
  );

  test('Tools preserves pairing and one fallback switch alongside NeoSwap', () {
    final tools = File(
      'lib/screens/settings_screen/new_settings_options/'
      'tools_settings_content.dart',
    ).readAsStringSync();

    expect(tools, contains('if (index == 0)'));
    expect(tools, contains('if (index == 1 && _jitFallbackStateLoaded'));
    expect(tools, contains('if (index == 2)'));
    expect(tools, contains('builder: (_) => const NeoSwapDialog()'));
    expect(tools, isNot(contains('index == 3')));
    expect(tools, isNot(contains('showNeoPlayDialog(context)')));
    expect(RegExp(r'CustomToggleSwitch\(').allMatches(tools).length, 1);
    expect(tools, isNot(contains('LocalJitTunnel')));
    expect(tools, isNot(contains('VPN')));
    expect(tools, contains('JitFallbackLocale.title'));
    expect(tools, contains('CustomToggleSwitch'));
    expect(tools, contains('setUseStikDebugFallback'));
  });
}
