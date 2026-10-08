import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_library_protocol.dart';

String payload(Object value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

void main() {
  test(
    'official export preserves filenames, Unicode and archive launch IDs',
    () {
      final entries = RetroArchLibraryProtocol.decode(
        payload([
          {
            'filename': 'Pokémon (France).zip#Pokémon.gbc',
            'titleId': 'Pokémon (France).zip#Pokémon.gbc',
            'system': 'Nintendo - Game Boy Color',
          },
          {'titleId': '4 in 1 Funpak (USA, Europe).gb'},
        ]),
      );
      final cache = RetroArchLibraryProtocol.index(entries);
      expect(
        cache['Pokémon (France).zip']!['filename'],
        'Pokémon (France).zip#Pokémon.gbc',
      );
      expect(
        cache['4 in 1 Funpak (USA, Europe)']!['titleId'],
        '4 in 1 Funpak (USA, Europe).gb',
      );
    },
  );

  test(
    'malformed callbacks are rejected atomically; empty is distinguishable',
    () {
      expect(RetroArchLibraryProtocol.decode(payload([])), isEmpty);
      for (final value in [
        {'games': []},
        [null],
        [
          {'filename': ''},
        ],
        [
          {'filename': 42},
        ],
        [
          {'filename': 'valid.gb'},
          {'titleName': 'missing ID'},
        ],
      ]) {
        expect(
          () => RetroArchLibraryProtocol.decode(payload(value)),
          throwsFormatException,
        );
      }
      expect(
        () => RetroArchLibraryProtocol.decode('not base64!'),
        throwsFormatException,
      );
    },
  );

  testWidgets('opening a URL does not complete a sync; callback does', (
    tester,
  ) async {
    final sync = RetroArchSyncController();
    var completed = false;
    final result = sync.request(() async => true).then((outcome) {
      completed = true;
      return outcome;
    });
    await tester.pump(const Duration(seconds: 1));
    expect(completed, isFalse);
    expect(sync.isPending, isTrue);
    sync.complete(RetroArchSyncOutcome.synced);
    expect(await result, RetroArchSyncOutcome.synced);
  });

  testWidgets('double taps send one export; no callback produces timeout', (
    tester,
  ) async {
    final sync = RetroArchSyncController(timeout: const Duration(seconds: 2));
    var sends = 0;
    Future<bool> send() async {
      sends++;
      return true;
    }

    final first = sync.request(send);
    final second = sync.request(send);
    expect(identical(first, second), isTrue);
    await tester.pump(const Duration(seconds: 3));
    expect(await first, RetroArchSyncOutcome.timedOut);
    expect(await second, RetroArchSyncOutcome.timedOut);
    expect(sends, 1);
    sync.complete(RetroArchSyncOutcome.synced);
    expect(sync.lastOutcome, RetroArchSyncOutcome.timedOut);
  });

  testWidgets('transport failure and exceptions remain failures', (
    tester,
  ) async {
    final sync = RetroArchSyncController();
    expect(
      await sync.request(() async => false),
      RetroArchSyncOutcome.unavailable,
    );
    expect(
      await sync.request(() => throw StateError('open rejected')),
      RetroArchSyncOutcome.unavailable,
    );
  });

  testWidgets(
    'callback can precede native completion without being overwritten',
    (tester) async {
      final sync = RetroArchSyncController();
      final accepted = Completer<bool>();
      final result = sync.request(() => accepted.future);
      sync.complete(RetroArchSyncOutcome.synced);
      accepted.complete(false);
      await tester.pump();
      expect(await result, RetroArchSyncOutcome.synced);
      expect(sync.lastOutcome, RetroArchSyncOutcome.synced);
    },
  );

  testWidgets(
    'empty or invalid callback finishes the request without success',
    (tester) async {
      for (final failure in [
        RetroArchSyncOutcome.empty,
        RetroArchSyncOutcome.invalid,
      ]) {
        final sync = RetroArchSyncController();
        final result = sync.request(() async => true);
        sync.complete(failure);
        expect(await result, failure);
        expect(sync.isPending, isFalse);
      }
    },
  );
}
