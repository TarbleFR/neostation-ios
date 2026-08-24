import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('system info tab is scrollable with D-pad navigation', () {
    final host = File('lib/widgets/system_emulator_settings_dialog.dart')
        .readAsStringSync();
    final nav = File(
      'lib/widgets/system_emulator_settings_dialog/gamepad_nav.dart',
    ).readAsStringSync();
    final info = File(
      'lib/widgets/system_emulator_settings_dialog/system_info.dart',
    ).readAsStringSync();

    expect(host, contains('_systemInfoScrollController = ScrollController()'));
    expect(host, contains('_systemInfoScrollController.dispose()'));
    expect(info, contains('controller: _systemInfoScrollController'));
    expect(nav, contains('void _scrollSystemInfo({required bool down})'));
    expect(nav, contains('_scrollSystemInfo(down: false)'));
    expect(nav, contains('_scrollSystemInfo(down: true)'));
  });

  test('scraper media keeps the selected option visible', () {
    final media = File(
      'lib/screens/scraper_screen/scraper_contents/media_content.dart',
    ).readAsStringSync();
    final screen = File(
      'lib/screens/scraper_screen/new_scraper_options_screen.dart',
    ).readAsStringSync();

    expect(media, contains('final List<GlobalKey> _itemKeys'));
    expect(media, contains('void ensureVisible(int index)'));
    expect(media, contains('key: _itemKeys[index]'));
    expect(screen, contains('_mediaKey.currentState?.ensureVisible'));
  });

  test('directory gamepad scrolling handles lazily built ROM rows', () {
    final directories = File(
      'lib/screens/settings_screen/new_settings_options/directories_settings_content.dart',
    ).readAsStringSync();

    expect(directories, contains('position.viewportDimension * 0.72'));
    expect(directories, contains('_lastScrollIndex'));
    expect(directories, contains('_scroller.ensureVisible(builtContext)'));
  });
}
