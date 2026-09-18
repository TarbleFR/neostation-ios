#!/usr/bin/env python3
"""Apply after 267/268/269 patches, never after the abandoned 270 changes.

Only networking and diagnostics change. The RPCS3 service undoes the 268 lease;
native JIT, helper, loader, emulation cores and shared scripts retain baseline.
"""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
RES=ROOT/'build-utils/vpn271'

def read(name): return (ROOT/name).read_text()
def write(name,text): (ROOT/name).write_text(text)
def change(name,old,new):
 text=read(name)
 if old not in text and (not new or new in text): return
 if text.count(old)!=1: raise RuntimeError(f'{name}: unexpected source anchor: {old[:70]}')
 write(name,text.replace(old,new,1))

def main():
 name='packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
 text=read(name)
 if 'NEOSTATION_VPN_CONTROL_271' not in text:
  if 'NEOSTATION_NATIVE_ROUTE_LEASE_270' in text: raise RuntimeError('Do not mix Build 270 into the 267 rollback')
  tail=text[text.index('  private func providerBundleIdentifier()'):text.index('// This code stays in the manager')]
  tail=tail.replace('(schema == 1 || schema == Constants.schemaVersion)', '(schema == 1 || schema == 2 || schema == Constants.schemaVersion)')
  write(name,(RES/'manager.swift.inc').read_text()+tail)
 # The retained tail ends before the removed extension's separator.
 # Keep one terminal newline on both fresh and already-patched sources.
 write(name,read(name).rstrip()+'\n')
 write('native/local_jit_tunnel/PacketTunnelProvider.swift',(RES/'provider.swift.inc').read_text())
 name='packages/stikjit_bridge/ios/Classes/StikjitBridgePlugin.swift'
 text=read(name)
 if '    if call.method == "beginDebuggerLease"' in text:
  a=text.index('    if call.method == "beginDebuggerLease"');b=text.index('    if call.method == "ensureLocalTunnel"',a)
  text=text[:a]+text[b:];write(name,text)
 change(name,'  public static func register(with registrar: FlutterPluginRegistrar) {\n    let channel',
        '  public static func register(with registrar: FlutterPluginRegistrar) {\n    NeoStationVPNDiagnostics.initialize()\n    let channel')
 name='lib/services/rpcs3_internal_service.dart'
 change(name,"import 'local_jit_debugger_lease.dart';\n",'')
 change(name,"        // Must be acknowledged BEFORE StikJIT can suspend this process.\n        await LocalJitDebuggerLease.acquire();\n        _log.i('RPCS3 debugger tunnel protection confirmed.');\n",'')
 change(name,"    } finally {\n      // Keep the lease through dlopen, arena preparation AND helper detach.\n      // Cleanup must never replace the actual initialization error.\n      try {\n        await LocalJitDebuggerLease.release();\n      } catch (error) {\n        _log.w('RPCS3 tunnel protection cleanup failed; provider expiry remains bounded: $error');\n      }\n",'')
 name='lib/services/local_jit_tunnel_service.dart';text=read(name)
 if 'static bool _manualOff' not in text:
  text=text.replace("import 'local_jit_debugger_lease.dart';\n",'')
  text=re.sub(r"    // A native helper transition.*?    }\n",'',text,flags=re.S)
  text=text.replace('  static int _lifecycleGeneration = 0;','  static int _lifecycleGeneration = 0;\n  static bool _manualOff = false;')
  text=text.replace('  static Future<LocalJitTunnelState> authorizeAndEnable() async {\n','  static Future<LocalJitTunnelState> authorizeAndEnable() async {\n    _manualOff = false;\n')
  text=text.replace('    ++_lifecycleGeneration;\n    return _session.stop();','    ++_lifecycleGeneration;\n    _manualOff = true;\n    return _session.stop();')
  text=text.replace('    final generation = ++_lifecycleGeneration;','    if (_manualOff) return;\n    final generation = ++_lifecycleGeneration;')
  write(name,text)
 write('lib/services/local_jit_session_coordinator.dart', '''/// Build 271: cancellation without a destructive startup reset. The native
/// manager coalesces commands and bounds every preferences operation.
class LocalJitSessionCoordinator<T> {
  LocalJitSessionCoordinator({
    required Future<T> Function() ensureRoute,
    required Future<T> Function() stopTunnel,
    required void Function(Object error) onResetError,
  }) : _ensureRoute = ensureRoute, _stopTunnel = stopTunnel;
  final Future<T> Function() _ensureRoute;
  final Future<T> Function() _stopTunnel;
  int _generation = 0;
  Future<T> ensure({Future<T> Function()? routeOverride}) async {
    final generation = _generation;
    final route = await (routeOverride ?? _ensureRoute)();
    if (generation != _generation) throw const LocalJitSessionCancelled();
    return route;
  }
  Future<T> stop() { ++_generation; return _stopTunnel(); }
}
class LocalJitSessionCancelled implements Exception {
  const LocalJitSessionCancelled();
}
''')
 write('lib/services/local_jit_lifecycle_policy.dart', '''import 'package:flutter/widgets.dart';

/// Native helper/authorization UI may hide or suspend the frontend. Keep the
/// route independent of it. Explicit OFF and actual app teardown still stop.
bool shouldStopLocalJitForLifecycle(AppLifecycleState state) =>
    state == AppLifecycleState.detached;
''')
 name='lib/widgets/app_lifecycle_handler.dart'
 change(name,'On iOS it also enforces the session-only lifetime of NeoStationLocalTunnel.', 'On iOS explicit teardown stops NeoStationLocalTunnel; helper transitions do not.')
 change(name,'// AppLifecycleState.paused/hidden/detached still stop immediately.', '// Only detached is an unambiguous teardown, not a helper transition.')
 name='packages/stikjit_bridge/lib/stikjit_bridge.dart';text=read(name)
 if 'build=271; bridge=' not in text:
  text="import 'dart:async';\n\n"+text
  for method,seconds in [('ensureLocalTunnel',35),('activateOwnedTunnel',35),('localTunnelStatus',6),('disableLocalTunnel',12)]:
   old=f"await _channel.invokeMethod<Object?>('{method}');"
   new=f"await _channel.invokeMethod<Object?>('{method}').timeout(\n      const Duration(seconds: {seconds}),\n      onTimeout: () => throw PlatformException(\n        code: 'local_tunnel_connection_timeout',\n        message: 'build=271; bridge={method}; no native response after {seconds}s. Diagnostic-VPN-RPCS3.txt',\n      ),\n    );"
   if text.count(old)!=1: raise RuntimeError('Unexpected VPN bridge: '+method)
   text=text.replace(old,new)
  write(name,text)
 name='lib/screens/settings_screen/new_settings_options/tools_settings_content.dart';text=read(name)
 if '_tunnelRequestId' not in text:
  text=text.replace('  bool _isUpdatingTunnel = false;', '  bool _isUpdatingTunnel = false;\n  int _tunnelRequestId = 0;\n  String? _tunnelFailureDetail;')
  text=text.replace('    if (!_tunnelStateLoaded || _isUpdatingTunnel) return;\n    var previous = _tunnelState;\n    final disable = _shouldDisableTunnel(previous);','    if (!_tunnelStateLoaded || (_isUpdatingTunnel && _isDisablingTunnel)) return;\n    final request = ++_tunnelRequestId;\n    final previous = _tunnelState;\n    final disable = _isUpdatingTunnel || _shouldDisableTunnel(previous);')
  a=text.index('  Future<void> _toggleTunnel()');b=text.index('  Future<void> _refreshPairingState()',a);body=text[a:b]
  body=body.replace('_tunnelErrorCode = null;','_tunnelErrorCode = null;\n      _tunnelFailureDetail = null;')
  body=body.replace('      previous = await LocalJitTunnelService.status();\n      if (!mounted) return;\n      setState(() { _tunnelState = previous; _isDisablingTunnel = disable; });\n      final wasAuthorized = previous.authorized;','      final wasAuthorized = previous?.authorized == true;')
  body=body.replace('      try { previous = await LocalJitTunnelService.status(); } catch (_) {}\n','')
  body=body.replace('if (!mounted) return;','if (!mounted || request != _tunnelRequestId) return;').replace('if (mounted) {','if (mounted && request == _tunnelRequestId) {')
  body=body.replace('_tunnelErrorCode = error.code;','_tunnelErrorCode = error.code;\n        _tunnelFailureDetail = error.message;')
  text=text[:a]+body+text[b:]
  text=text.replace('                          _isUpdatingTunnel ||\n                          tunnelState?.status','                          (_isUpdatingTunnel && _isDisablingTunnel) ||\n                          tunnelState?.status')
  text=text.replace('trailing: !_tunnelStateLoaded || _isUpdatingTunnel','trailing: !_tunnelStateLoaded || (_isUpdatingTunnel && _isDisablingTunnel)')
  text=text.replace('LocalJitTunnelLocale.get(context, tunnelActionKey),','LocalJitTunnelLocale.get(context, _isUpdatingTunnel ? LocalJitTunnelLocale.disableAction : tunnelActionKey),')
  text=text.replace('(_tunnelState?.lastErrorDetail?.isNotEmpty ?? false)','((_tunnelFailureDetail ?? _tunnelState?.lastErrorDetail)?.isNotEmpty ?? false)')
  text=text.replace('_tunnelState!.lastErrorDetail!,',"'${_tunnelFailureDetail ?? _tunnelState?.lastErrorDetail}\\nDiagnostic-VPN-RPCS3.txt',")
  write(name,text)
 # Revise tests for intentionally removed reset/auto-stop behavior. Coverage of
 # missing callbacks, cancellation and native effects is added in vpn_build271.
 write('test/local_jit_session_coordinator_test.dart', '''import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/local_jit_session_coordinator.dart';

void main() {
  test('a working route is never preceded by a destructive reset', () async {
    var stops = 0;
    final session = LocalJitSessionCoordinator<String>(
      ensureRoute: () async => 'external',
      stopTunnel: () async { stops++; return 'off'; }, onResetError: (_) {},
    );
    expect(await session.ensure(), 'external');
    expect(await session.ensure(), 'external');
    expect(stops, 0);
  });
  test('manual stop rejects an old route without blocking a newer request', () async {
    final reply = Completer<String>();
    var requests = 0;
    final session = LocalJitSessionCoordinator<String>(
      ensureRoute: () => ++requests == 1 ? reply.future : Future.value('new'),
      stopTunnel: () async => 'off', onResetError: (_) {},
    );
    final old = session.ensure();
    final rejected = expectLater(old, throwsA(isA<LocalJitSessionCancelled>()));
    expect(await session.stop(), 'off');
    expect(await session.ensure(), 'new');
    reply.complete('obsolete');
    await rejected;
  });
  test('missing preferences access does not affect external route use', () async {
    final session = LocalJitSessionCoordinator<String>(
      ensureRoute: () async => 'external', stopTunnel: () async => throw StateError('unavailable'),
      onResetError: (_) {},
    );
    expect(await session.ensure(), 'external');
  });
  test('a failed route is never accepted', () async {
    final session = LocalJitSessionCoordinator<String>(
      ensureRoute: () async => throw StateError('no route'),
      stopTunnel: () async => 'off', onResetError: (_) {},
    );
    await expectLater(session.ensure(), throwsStateError);
  });
}
''')
 write('test/local_jit_lifecycle_policy_test.dart', '''import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/local_jit_lifecycle_policy.dart';

void main() {
  test('native helper and authorization transitions preserve the route', () {
    for (final state in [AppLifecycleState.resumed, AppLifecycleState.inactive,
        AppLifecycleState.paused, AppLifecycleState.hidden]) {
      expect(shouldStopLocalJitForLifecycle(state), isFalse, reason: state.name);
    }
  });
  test('actual teardown still stops the owned route', () {
    expect(shouldStopLocalJitForLifecycle(AppLifecycleState.detached), isTrue);
  });
}
''')
 name='test/local_tunnel_build269_test.dart';text=read(name)
 if "  test('manual override waits" in text:
  a=text.index("  test('manual override waits")
  write(name,text[:a]+'''  test('manual and automatic commands retain their intent without a reset', () async {
    final calls = <String>[];
    final coordinator = LocalJitSessionCoordinator<String>(
      ensureRoute: () async { calls.add('automatic'); return 'external'; },
      stopTunnel: () async { calls.add('off'); return 'off'; }, onResetError: (_) {},
    );
    expect(await coordinator.ensure(), 'external');
    expect(await coordinator.ensure(routeOverride: () async { calls.add('owned'); return 'owned'; }), 'owned');
    expect(calls, ['automatic', 'owned']);
  });
  test('OFF cancels a pending owned activation result', () async {
    final activation = Completer<String>();
    final coordinator = LocalJitSessionCoordinator<String>(
      ensureRoute: () async => 'external', stopTunnel: () async => 'off', onResetError: (_) {},
    );
    final pending = coordinator.ensure(routeOverride: () => activation.future);
    final rejected = expectLater(pending, throwsA(isA<LocalJitSessionCancelled>()));
    await coordinator.stop();
    activation.complete('obsolete-owned');
    await rejected;
  });
}
''')
 print('Build 271: bounded VPN commands, no host-dependent watchdog, RPCS3 267 launch, automatic local TXT diagnostics.')

if __name__=='__main__':main()
