#!/usr/bin/env python3
"""Build 273 VPN-only policy.

Apply after Build 271. This file must not modify RPCS3, StikJIT helper/core,
Dolphin, shaders, or any emulator launch logic beyond the shared read-only
route probe. VPN mutations are reachable only from explicit Settings ON/OFF.
"""
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def read(name): return (ROOT/name).read_text()
def write(name,text): (ROOT/name).write_text(text)
def change(name,old,new):
    text=read(name)
    if old not in text and (not new or new in text): return
    if text.count(old)!=1:
        raise RuntimeError(f"{name}: unexpected source anchor: {old[:90]}")
    write(name,text.replace(old,new,1))

VPN_ENTRY = r'''  // NEOSTATION_VPN_MANUAL_ONLY_273: observation never mutates VPN profiles.
  func ensureRunning(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      // Game/JIT preflight is TCP-only. It deliberately runs before and
      // independently of NetworkExtension preferences/signing.
      self.probeJitRoute { ready in
        NeoStationVPNDiagnostics.record(
          "route",
          ready
            ? "NEOSTATION_VPN_MANUAL_ONLY_273: endpoint reachable; VPN unchanged"
            : "NEOSTATION_VPN_MANUAL_ONLY_273: endpoint unavailable; VPN unchanged"
        )
        if ready {
          completion(.success(self.externalRouteResponse()))
        } else {
          completion(.failure(.routeUnavailable))
        }
      }
    }
  }

  // Explicit Settings ON is the only path that may start/save our VPN profile.
  func enableOwned(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      if let previous = self.current, previous.intent == "activate-owned" {
        previous.waiters.append(completion)
        return
      }
      let request = self.begin("activate-owned", seconds: 30, completion: completion)
      if let manager = self.activeManager, manager.connection.status == .connected {
        self.verify(manager, request)
        return
      }
      self.loadForStart(request)
    }
  }

'''

SERVICE = r'''import 'dart:io';

import 'package:flutter/services.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

/// VPN policy: games only observe route reachability.
/// Only explicit Settings actions may start or stop NeoStation's tunnel.
class LocalJitTunnelService {
  LocalJitTunnelService._();

  static Future<LocalJitTunnelState> status() async {
    if (!Platform.isIOS) {
      return const LocalJitTunnelState(
        active: false,
        status: 'unsupported',
        managedByNeoStation: true,
        configured: false,
        authorized: false,
        enabled: false,
        interfaceAddress: null,
        peerAddress: null,
        onDemand: false,
      );
    }
    try {
      return await StikjitBridge.localTunnelStatus();
    } on PlatformException catch (error) {
      throw _error(error);
    }
  }

  /// Game/JIT entry point. TCP observation only: no profile load/save/start/stop.
  static Future<LocalJitTunnelState> ensureRunningForJit() async {
    if (!Platform.isIOS) {
      throw const LocalJitTunnelException(
        'unsupportedPlatform',
        'Local JIT requires iOS.',
      );
    }
    try {
      return await StikjitBridge.ensureJitRoute();
    } on PlatformException catch (error) {
      throw _error(error);
    }
  }

  /// Explicit Settings action only.
  static Future<LocalJitTunnelState> authorizeAndEnable() async {
    if (!Platform.isIOS) {
      throw const LocalJitTunnelException(
        'unsupportedPlatform',
        'The integrated VPN requires iOS.',
      );
    }
    try {
      return await StikjitBridge.activateOwnedTunnel();
    } on PlatformException catch (error) {
      throw _error(error);
    }
  }

  /// Explicit Settings action only.
  static Future<LocalJitTunnelState> disable() async {
    if (!Platform.isIOS) {
      throw const LocalJitTunnelException(
        'unsupportedPlatform',
        'The integrated VPN requires iOS.',
      );
    }
    try {
      return await StikjitBridge.disableLocalTunnel();
    } on PlatformException catch (error) {
      throw _error(error);
    }
  }

  static LocalJitTunnelException _error(PlatformException error) =>
      LocalJitTunnelException(
        error.code,
        error.message ?? 'The selected VPN route is unavailable.',
      );
}

class LocalJitTunnelException implements Exception {
  const LocalJitTunnelException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => message;
}
'''

POLICY = r'''import 'package:flutter/widgets.dart';

/// App lifecycle is never an authority over the user's VPN choice.
/// Only the explicit Settings switch may stop the integrated VPN.
bool shouldStopLocalJitForLifecycle(AppLifecycleState state) => false;
'''

def main():
    # 1) Native manager: game preflight becomes a pure TCP observation.
    name='packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
    text=read(name)
    if 'NEOSTATION_VPN_MANUAL_ONLY_273' not in text:
        start=text.index('  func ensureRunning(')
        end=text.index('  func status(', start)
        write(name, text[:start] + VPN_ENTRY + text[end:])
    change(
        name,
        '"status": "externalRoute"',
        '"status": "reachableRoute"',
    )
    change(
        name,
        'return "The local tunnel connected, but the StikJIT route at 10.7.0.1:49152 is not reachable."',
        'return "The selected local JIT route at 10.7.0.1:49152 is not reachable. NeoStation did not change any VPN."',
    )

    # 2) Dart service: strict separation between read-only preflight and manual ON/OFF.
    write('lib/services/local_jit_tunnel_service.dart', SERVICE)

    # 3) App lifecycle: never start/stop/save a VPN on cold start, resume, exit or detach.
    name='lib/widgets/app_lifecycle_handler.dart'
    text=read(name)
    if 'VPN profiles and tunnels are independent of this widget and app lifetime.' not in text:
        for target in (
            "import 'dart:async';\n",
            "import 'package:neostation/services/local_jit_tunnel_service.dart';\n",
            "import 'package:neostation/services/local_jit_lifecycle_policy.dart';\n",
        ):
            text=text.replace(target,'')
        blocks=[
            """        if (Platform.isIOS) {
          await LocalJitTunnelService.stopForLifecycle(
            reason: 'normal app exit',
          );
        }
""",
            """    if (Platform.isIOS) {
      unawaited(
        LocalJitTunnelService.stopForLifecycle(reason: 'lifecycle disposed'),
      );
    }
""",
            """      // Begin route selection immediately. This probes an existing external
      // LocalDevVPN route before deciding whether NeoStationLocalTunnel is
      // needed, while the rest of resume housekeeping proceeds normally.
      if (Platform.isIOS) {
        unawaited(
          LocalJitTunnelService.refreshInBackground(reason: 'app resume'),
        );
      }
""",
            """    // AppLifecycleState.inactive can be a native VPN permission dialog, not
    // a background transition. Do not invalidate the authorization it awaits.
    // Only detached is an unambiguous teardown, not a helper transition.
    if (Platform.isIOS && shouldStopLocalJitForLifecycle(state)) {
      unawaited(
        LocalJitTunnelService.stopForLifecycle(
          reason: 'app lifecycle ${state.name}',
        ),
      );
    }
""",
        ]
        for block in blocks:
            if block in text:
                text=text.replace(block,'',1)
        text=text.replace(
            'On iOS explicit teardown stops NeoStationLocalTunnel; helper transitions do not.',
            'VPN profiles and tunnels are independent of this widget and app lifetime.',
        )
        write(name,text)

    name='lib/main.dart'
    text=read(name)
    text=text.replace("import 'package:neostation/services/local_jit_tunnel_service.dart';\n",'')
    text=text.replace(
        """  if (Platform.isIOS) {
    // The system-owned Packet Tunnel continues outside the Flutter lifecycle.
    // Do not delay the frontend while iOS restores or authorizes it.
    unawaited(
      LocalJitTunnelService.refreshInBackground(reason: 'cold start'),
    );
  }
""",
        '',
    )
    write(name,text)
    write('lib/services/local_jit_lifecycle_policy.dart', POLICY)
    write('test/local_jit_lifecycle_policy_test.dart', r'''import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/local_jit_lifecycle_policy.dart';

void main() {
  test('no application lifecycle state controls the user VPN choice', () {
    for (final state in AppLifecycleState.values) {
      expect(
        shouldStopLocalJitForLifecycle(state),
        isFalse,
        reason: state.name,
      );
    }
  });
}
''')

    # 4) Read-only probe must fail quickly and may never wait 35 seconds.
    name='packages/stikjit_bridge/lib/stikjit_bridge.dart'
    text=read(name)
    old="""await _channel.invokeMethod<Object?>('ensureLocalTunnel').timeout(
      const Duration(seconds: 35)"""
    new="""await _channel.invokeMethod<Object?>('ensureLocalTunnel').timeout(
      const Duration(seconds: 3)"""
    if old in text:
        text=text.replace(old,new,1)
    text=text.replace(
        'build=271; bridge=ensureLocalTunnel; no native response after 35s.',
        'build=273; bridge=ensureLocalTunnel; read-only probe did not respond after 3s.',
    )
    write(name,text)

    # 5) No source outside the VPN/lifecycle layer is touched by this patch.
    for forbidden in (
        'lib/services/rpcs3_internal_service.dart',
        'packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift',
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h',
        'native/local_jit_tunnel/PacketTunnelProvider.swift',
        'packages/dolphin_internal_bridge/ios/Classes/DolphinInternalBridgePlugin.mm',
    ):
        assert (ROOT/forbidden).exists(), forbidden

    print('Build 273 VPN-only: manual ON/OFF, persistent lifecycle, TCP-only game preflight, no emulator/core changes.')

if __name__=='__main__':
    main()
