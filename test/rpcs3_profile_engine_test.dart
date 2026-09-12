import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/rpcs3_config_adapter.dart';
import 'package:neostation/services/rpcs3_game_profile_database.dart';

void main() {
  test('bundles a complete, classified and iOS-safe RPCS3 database', () {
    final source = File(
      'assets/data/rpcs3_ios_profiles.json',
    ).readAsStringSync();
    final entries = Rpcs3GameProfileDatabase.parseDatabaseForTesting(source);
    expect(entries.length, greaterThanOrEqualTo(2000));
    expect(entries['BCUS98111'], isNotNull);
    expect(source, isNot(contains('Renderer: OpenGL')));
    expect(source, isNot(contains('Frame limit: Infinite')));
    expect(source, isNot(contains('Frame limit: Off')));

    final root = jsonDecode(source) as Map<String, dynamic>;
    expect(root['source_url'], Rpcs3GameProfileDatabase.sourceUrl);
    expect(root['policy'], isA<Map<String, dynamic>>());
  });

  test('merges nested scalar overrides without losing lists or siblings', () {
    const source = '''
Core:
  Libraries Control:
    - libvdec.sprx:lle
  SPU Block Size: Safe
Video:
  Vulkan:
    Asynchronous Texture Streaming: false
  Write Color Buffers: true
''';
    final merged = Rpcs3ConfigAdapter.mergeScalarOverrides(source, {
      const ['Core', 'SPU Block Size']: 'Mega',
      const ['Video', 'Vulkan', 'Asynchronous Texture Streaming']: 'true',
      const ['iOS Experimental', 'RSX FIFO Read Cache']: '4 KiB',
    });
    expect(merged, contains('- libvdec.sprx:lle'));
    expect(merged, contains('SPU Block Size: Mega'));
    expect(merged, contains('Write Color Buffers: true'));
    expect(merged, contains('Asynchronous Texture Streaming: true'));
    expect(merged, contains('iOS Experimental:\n  RSX FIFO Read Cache: 4 KiB'));
  });

  test('drops only desktop renderer and unbounded handheld frame limits', () {
    const source = '''
Video:
  Renderer: OpenGL
  Frame limit: Infinite
  Write Color Buffers: true
Core:
  Max SPURS Threads: 3
''';
    final result = Rpcs3ConfigAdapter.sanitiseForIOS(source);
    expect(result, isNot(contains('Renderer: OpenGL')));
    expect(result, isNot(contains('Frame limit: Infinite')));
    expect(result, contains('Write Color Buffers: true'));
    // Unlike ARMSX3, NeoStation does not strip this without Apple-SoC data.
    expect(result, contains('Max SPURS Threads: 3'));
  });
}
