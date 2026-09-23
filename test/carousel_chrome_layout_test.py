#!/usr/bin/env python3
"""Exercise the production carousel layout with Flutter's render/hit-test tree."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TEST = r'''
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/carousel_chrome_layout.dart';
void main() {
  for (final size in [const Size(844, 390), const Size(667, 375),
                     const Size(390, 844), const Size(1194, 834)]) {
    for (final unit in [1.0, 1.5]) {
      testWidgets('rail clears alphabet and footer: $size / $unit', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var tapped = 0;
        Widget build(bool hidden) => MaterialApp(home: Scaffold(body: CarouselChromeLayout(
          unit: unit, safeLeft: 47, safeRight: 21, legendHidden: hidden,
          artwork: const ColoredBox(key: Key('art'), color: Colors.black),
          letters: SizedBox(height: 30 * unit, child: SingleChildScrollView(
            scrollDirection: Axis.horizontal, child: Row(children: List.generate(26,
              (i) => GestureDetector(onTap: () { tapped++; }, child: SizedBox(
                key: Key('letter$i'), width: 30 * unit, child: Text('$i'))))))),
          footer: SizedBox(key: const Key('footer'), height: 55 * unit,
            child: const Text('Aguri Suzuki F-1 Super Driving', maxLines: 1, overflow: TextOverflow.ellipsis)),
          legend: SizedBox(key: const Key('rail'), width: 50 * unit, height: 330 * unit),
          edgeReshowZone: const SizedBox(),
        )));
        await tester.pumpWidget(build(false));
        final rail = tester.getRect(find.byKey(const Key('rail')));
        final letter = tester.getRect(find.byKey(const Key('letter0')));
        final footer = tester.getRect(find.byKey(const Key('footer')));
        expect(rail.overlaps(letter), isFalse);
        expect(rail.overlaps(footer), isFalse);
        expect(rail.right, lessThan(letter.left));
        expect(rail.right, lessThan(footer.left));
        await tester.tap(find.byKey(const Key('letter0')));
        expect(tapped, 1);
        for (final hidden in [true, false]) {
          await tester.pumpWidget(build(hidden));
          await tester.pump(const Duration(milliseconds: 125));
          expect(tester.getRect(find.byKey(const Key('rail'))).overlaps(footer), isFalse);
          await tester.pumpAndSettle();
          expect(tester.getRect(find.byKey(const Key('footer'))), footer);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
'''
with tempfile.TemporaryDirectory(prefix='neostation-carousel-') as directory:
    root = Path(directory)
    (root / 'lib').mkdir()
    (root / 'test').mkdir()
    (root / 'lib/carousel_chrome_layout.dart').write_text(
        (ROOT / 'lib/widgets/carousel_chrome_layout.dart').read_text())
    (root / 'pubspec.yaml').write_text('''name: carousel_layout_harness
environment:
  sdk: '>=3.9.2 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
dev_dependencies:
  flutter_test:
    sdk: flutter
''')
    (root / 'test/layout_test.dart').write_text(TEST)
    subprocess.run([os.environ.get('FLUTTER_BIN', 'flutter'), 'test', '--reporter', 'expanded'],
                   cwd=root, check=True)
