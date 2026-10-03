import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// PathProvider's supported testing interface is supplied transitively by the
// existing path_provider dependency; no runtime dependency is added for tests.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:retroarch_internal_bridge/retroarch_internal_bridge.dart';
import 'package:neostation/services/embedded_ios_session_status.dart';
import 'package:neostation/services/frontend_media_gate.dart';
import 'package:neostation/services/retroarch_internal_service.dart';

class _DocumentsPath extends PathProviderPlatform {
  _DocumentsPath(this.directory);
  final String directory;
  @override
  Future<String?> getApplicationDocumentsPath() async => directory;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neostation/retroarch_internal');
  const codec = StandardMethodCodec();
  var transaction = 0;

  Future<void> nativeEvent(String type, {int? fromTransaction}) async {
    final delivered = Completer<void>();
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall(type, <String, dynamic>{
          'transaction': fromTransaction ?? transaction,
          'reason': 'userReturn',
          'runtimeReleased': type == 'sessionEnded',
        }),
      ),
      (_) => delivered.complete(),
    );
    await delivered.future;
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'native ownership keeps frontend quiet through menu, failure and relaunch',
    () async {
      final documents = await Directory.systemTemp.createTemp(
        'retroarch-lifecycle-',
      );
      final previousPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _DocumentsPath(documents.path);
      final game = File('${documents.path}/game.nes');
      await game.writeAsBytes([1, 2, 3, 4]);
      var nativeLaunches = 0;
      var stopCalls = 0;
      var timeout = false;
      var stopAcknowledged = false;
      var launchThrows = false;
      Completer<void>? relaunchPreparation;
      var backendAvailable = true;
      Object? packagedMetadata = <String>[
        'fceumm',
        'dolphin',
        'unreviewed_core',
      ];
      var diagnosticsThrows = false;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'diagnostics') {
          if (diagnosticsThrows) {
            throw PlatformException(code: 'native_metadata_unavailable');
          }
          return <String, dynamic>{
            'backendAvailable': backendAvailable,
            'availableCoreIds': packagedMetadata,
          };
        }
        if (call.method == 'launch') {
          nativeLaunches++;
          transaction = (call.arguments as Map)['transaction'] as int;
          expect((call.arguments as Map)['coreId'], 'fceumm');
          if (launchThrows) {
            throw PlatformException(code: 'native_channel_failure');
          }
          return <String, dynamic>{
            'transaction': transaction,
            'success': !timeout,
            'stage': timeout ? 'first_frame_timeout' : 'first_frame',
            'errorCode': timeout ? 'RETROARCH_FIRST_FRAME_TIMEOUT' : null,
            'detail': timeout ? 'Original native failure details' : null,
            'sessionOwned': true,
            'logPath': '${documents.path}/RetroArch/logs/runtime.log',
          };
        }
        if (call.method == 'stop') {
          stopCalls++;
          expect((call.arguments as Map)['transaction'], transaction);
          // Teardown is deliberately not acknowledged yet.
          return {
            'success': true,
            'stage': 'stop_requested',
            'sessionOwned': !stopAcknowledged,
          };
        }
        throw PlatformException(code: 'unsupported_mock_method');
      });
      try {
        expect(await RetroArchInternalService.availableCoreIdentifiers(), {
          'fceumm',
        });
        backendAvailable = false;
        expect(await RetroArchInternalService.packagedCoreIdentifiers(), {
          'fceumm',
        });
        expect(
          await RetroArchInternalService.availableCoreIdentifiers(),
          isEmpty,
        );
        expect(await RetroArchInternalService.frontendAvailable(), isFalse);
        backendAvailable = true;
        final validMetadata = packagedMetadata;
        for (final invalidMetadata in <Object?>[
          null,
          'fceumm',
          <Object>['fceumm', 42],
        ]) {
          packagedMetadata = invalidMetadata;
          await expectLater(
            RetroArchInternalService.packagedCoreIdentifiers(),
            throwsFormatException,
          );
          expect(
            await RetroArchInternalService.availableCoreIdentifiers(),
            isEmpty,
          );
        }
        packagedMetadata = <String>[];
        expect(
          await RetroArchInternalService.packagedCoreIdentifiers(),
          isEmpty,
        );
        diagnosticsThrows = true;
        await expectLater(
          RetroArchInternalService.packagedCoreIdentifiers(),
          throwsA(isA<PlatformException>()),
        );
        expect(await RetroArchInternalService.frontendAvailable(), isFalse);
        diagnosticsThrows = false;
        packagedMetadata = validMetadata;

        Future<RetroArchLaunchResult> launch({String? inputPath}) =>
            RetroArchInternalService.launch(
              systemFolderName: 'nes',
              coreId: 'fceumm',
              gamePath: inputPath ?? game.path,
              gameTitle: 'Test',
              locale: 'fr',
              uiText: const {'quitGame': 'Retour'},
            );
        final virtual = await launch(inputPath: 'retroarch://game/game.nes');
        expect(virtual.errorCode, 'RETROARCH_GAME_IMPORT_REQUIRED');
        expect(virtual.detail, contains('retroarch://game/game.nes'));
        expect(nativeLaunches, 0);
        expect(FrontendMediaGate.instance.blocked, isFalse);
        final missing = await launch(
          inputPath: '${documents.path}/missing.nes',
        );
        expect(missing.errorCode, 'RETROARCH_GAME_UNREADABLE');
        expect(missing.detail, contains('missing.nes'));
        expect(nativeLaunches, 0);
        expect(FrontendMediaGate.instance.blocked, isFalse);
        final first = await launch();
        expect(first.success, isTrue);
        expect(FrontendMediaGate.instance.blocked, isTrue);
        await nativeEvent('sessionEvent');
        expect(RetroArchInternalBridge.hasSession, isTrue);
        expect(FrontendMediaGate.instance.blocked, isTrue);
        expect((await launch()).errorCode, 'RETROARCH_SESSION_ACTIVE');
        expect(nativeLaunches, 1);
        final firstTransaction = transaction;
        await nativeEvent('sessionEnded');
        expect(RetroArchInternalBridge.hasSession, isFalse);
        expect(FrontendMediaGate.instance.blocked, isFalse);

        relaunchPreparation = Completer<void>();
        FrontendMediaGate.instance.register(
          'relaunchPreparation',
          () => relaunchPreparation!.future,
        );
        final preparing = launch();
        await Future<void>.delayed(Duration.zero);
        await nativeEvent('sessionEnded', fromTransaction: firstTransaction);
        expect(nativeLaunches, 1);
        expect(
          FrontendMediaGate.instance.blocked,
          isTrue,
          reason:
              'An old end event cannot release a new launch before its native transaction exists.',
        );
        relaunchPreparation.complete();
        expect((await preparing).success, isTrue);
        FrontendMediaGate.instance.unregister('relaunchPreparation');
        expect(transaction, greaterThan(firstTransaction));
        await nativeEvent('sessionEnded', fromTransaction: firstTransaction);
        expect(
          RetroArchInternalBridge.hasSession,
          isTrue,
          reason: 'An old native callback cannot release a newer renderer.',
        );
        expect(FrontendMediaGate.instance.blocked, isTrue);
        await nativeEvent('sessionEnded');

        timeout = true;
        final failed = await launch();
        expect(failed.success, isFalse);
        expect(failed.errorCode, 'RETROARCH_FIRST_FRAME_TIMEOUT');
        expect(
          failed.technicalDetails,
          contains('Original native failure details'),
        );
        expect(stopCalls, 1);
        expect(failed.sessionOwned, isTrue);
        var audioMayResume = false;
        final released = RetroArchInternalService.waitForSessionEnd().then((_) {
          audioMayResume = true;
        });
        await Future<void>.delayed(Duration.zero);
        expect(audioMayResume, isFalse);
        expect(FrontendMediaGate.instance.blocked, isTrue);
        expect((await launch()).errorCode, 'RETROARCH_SESSION_ACTIVE');
        expect(nativeLaunches, 3);
        await nativeEvent('sessionEnded');
        await released;
        expect(audioMayResume, isTrue);
        expect(FrontendMediaGate.instance.blocked, isFalse);

        timeout = false;
        expect((await launch()).success, isTrue);
        await nativeEvent('sessionEnded');
        expect(nativeLaunches, 4);

        timeout = true;
        stopAcknowledged = true;
        final stoppedFailure = await launch();
        expect(stoppedFailure.success, isFalse);
        expect(stoppedFailure.sessionOwned, isFalse);
        expect(
          FrontendMediaGate.instance.blocked,
          isFalse,
          reason:
              'An acknowledged stop can release its media barrier without a duplicate end event.',
        );
        final stoppedTransaction = transaction;
        timeout = false;
        expect((await launch()).success, isTrue);
        await nativeEvent('sessionEnded', fromTransaction: stoppedTransaction);
        expect(FrontendMediaGate.instance.blocked, isTrue);
        await nativeEvent('sessionEnded');
        expect(nativeLaunches, 6);

        launchThrows = true;
        stopAcknowledged = false;
        final bridgeFailure = await launch();
        expect(bridgeFailure.success, isFalse);
        expect(bridgeFailure.errorCode, 'RETROARCH_BRIDGE_ERROR');
        expect(bridgeFailure.detail, contains('native_channel_failure'));
        expect(
          bridgeFailure.sessionOwned,
          isTrue,
          reason:
              'A partial diagnostics map does not prove a failed channel released native ownership.',
        );
        expect(FrontendMediaGate.instance.blocked, isTrue);
        await nativeEvent('sessionEnded');
        expect(FrontendMediaGate.instance.blocked, isFalse);
        expect(
          await File(
            '${documents.path}/RetroArch/logs/neostation-retroarch.log',
          ).exists(),
          isTrue,
        );
        for (final folder in [
          'system',
          'games',
          'saves',
          'states',
          'config',
          'shaders',
          'overlays',
          'cheats',
        ]) {
          expect(
            await Directory('${documents.path}/RetroArch/$folder').exists(),
            isTrue,
          );
        }
        await expectLater(
          RetroArchInternalService.gamesDirectory('../escape'),
          throwsArgumentError,
        );
        launchThrows = false;
        final external = await Directory.systemTemp.createTemp(
          'retroarch-linked-',
        );
        try {
          final externalGame = File('${external.path}/linked.nes');
          await externalGame.writeAsBytes([1, 2, 3]);
          expect(externalGame.path.startsWith(documents.path), isFalse);
          expect((await launch(inputPath: externalGame.path)).success, isTrue);
          expect(FrontendMediaGate.instance.blocked, isTrue);
          await nativeEvent('sessionEnded');
          expect(FrontendMediaGate.instance.blocked, isFalse);
        } finally {
          await external.delete(recursive: true);
        }
      } finally {
        FrontendMediaGate.instance.unregister('relaunchPreparation');
        if (relaunchPreparation != null && !relaunchPreparation.isCompleted) {
          relaunchPreparation.complete();
        }
        if (RetroArchInternalBridge.hasSession) {
          await nativeEvent('sessionEnded');
        }
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        PathProviderPlatform.instance = previousPathProvider;
        await documents.delete(recursive: true);
      }
    },
  );

  test('RetroArch failed liveness probes never imply native exit', () async {
    expect(EmbeddedIOSSessionStatus.handles('ios_retroarch_internal'), isTrue);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      expect(call.method, 'isSessionActive');
      throw PlatformException(code: 'transient');
    });
    expect(
      await EmbeddedIOSSessionStatus.isActive('ios_retroarch_internal'),
      isTrue,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => false,
    );
    expect(
      await EmbeddedIOSSessionStatus.isActive('ios_retroarch_internal'),
      isFalse,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });
}
