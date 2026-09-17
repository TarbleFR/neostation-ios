#!/usr/bin/env python3
"""Build 269 regressions using real manager/provider Swift and simulated iOS.

No test below claims real-device VPN/signing/JIT validation. NetworkExtension
objects are test doubles; production queue, startup, recovery and packet code
are compiled and executed unchanged.
"""
from pathlib import Path
import subprocess
import local_jit_transport_behavior_test as transport
from local_jit_state_machine_check import check_state_machine

ROOT = Path(__file__).resolve().parents[1]
M = ROOT / 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
P = ROOT / 'native/local_jit_tunnel/PacketTunnelProvider.swift'

# Reuse the existing fixture helpers, not its test scenarios.
HELPERS = transport.MANAGER_TESTS.split('DispatchQueue.global().async {', 1)[0]
SCENARIOS = r'''
DispatchQueue.global().async {
  // Manual ON must not coalesce into an earlier automatic external success.
  let owned = main { profile(true, .disconnected) }
  let external = main { profile(false, .connected) } // Not returned by Apple's per-app API.
  let manager = main { NeoStationLocalTunnelManager.makeForTest() }
  setup([owned], [true, true])
  let automatic = ResultBox(), manual = ResultBox()
  manager.ensureRunning(completion: automatic.record)
  manager.enableOwned(completion: manual.record)
  wait("mixed intent", { automatic.results.count == 1 && manual.results.count == 1 })
  main {
    require(automatic.success?["managedByNeoStation"] as? Bool == false, "automatic external route retained")
    require(manual.success?["managedByNeoStation"] as? Bool == true, "manual result belongs to NeoStation")
    require(owned.connection.starts == 1, "manual ON issued a real start")
    require(TestPlatform.probes.isEmpty, "manual does not run the external shortcut probe")
    require(external.connection.stops == 0 && external.saves == 0, "LocalDevVPN is not controlled")
    manager.stopTestHeartbeat()
  }

  // A provider already connected outside this manager instance is owned, not
  // an external route whose heartbeat would be stopped accidentally.
  let adopted = main { profile(true, .connected) }
  let adopter = main { NeoStationLocalTunnelManager.makeForTest() }
  setup([adopted], [true])
  let adoption = ResultBox()
  adopter.ensureRunning(completion: adoption.record)
  wait("adopt own provider", { adoption.results.count == 1 })
  main {
    require(adoption.success?["managedByNeoStation"] as? Bool == true, "adopt known owned provider")
    require(adopted.connection.starts == 0 && adopted.saves == 0, "healthy provider is not reconfigured")
    require((adopted.connection as! NETunnelProviderSession).messages > 0, "owned provider acknowledged")
    adopter.stopTestHeartbeat()
  }

  // Reconfigure only after a previous connecting/disconnecting session stops.
  let stale = main { profile(true, .connecting) }
  main {
    stale.connection.onStop = { connection in
      require(stale.saves == 0, "stop precedes profile save")
      connection.status = .disconnecting
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { connection.status = .disconnected }
    }
    stale.connection.onStart = { connection in
      require(stale.saves == 1 && connection.stops == 1, "one ordered stop/save/start")
      connection.status = .connected
    }
  }
  setup([stale], [true])
  let cleaner = main { NeoStationLocalTunnelManager.makeForTest() }
  let cleanResult = ResultBox()
  cleaner.enableOwned(completion: cleanResult.record)
  wait("clean stale profile", { cleanResult.results.count == 1 })
  main { require(cleanResult.success != nil, "stale profile repaired"); cleaner.stopTestHeartbeat() }

  // First start remains connecting (the video failure). Exactly one ordered
  // stop/reload/start recovery can turn it into a verified successful route.
  let recoverable = main { profile(true, .disconnected) }
  main {
    recoverable.connection.onStart = { connection in
      connection.status = connection.starts == 1 ? .connecting : .connected
    }
  }
  setup([recoverable], [true])
  let recovery = main { NeoStationLocalTunnelManager.makeForTest() }
  let recovered = ResultBox()
  recovery.enableOwned(completion: recovered.record)
  wait("bounded recovery", { recovered.results.count == 1 })
  main {
    require(recovered.success != nil && recoverable.connection.starts == 2, "one recovery start succeeds")
    require(recoverable.connection.stops == 1, "recovery awaited a clean stop")
    recovery.stopTestHeartbeat()
  }

  // TCP from another route cannot validate an owned provider that does not
  // acknowledge its own IPC heartbeat.
  let silent = main { profile(true, .disconnected) }
  main { (silent.connection as! NETunnelProviderSession).acknowledgeHeartbeat = false }
  setup([silent], [])
  let silentManager = main { NeoStationLocalTunnelManager.makeForTest() }
  let noProof = ResultBox()
  silentManager.enableOwned(completion: noProof.record)
  wait("provider proof", { noProof.results.count == 1 })
  main {
    require(noProof.error?.code == "jit_route_unavailable", "silent owned provider is not ready")
    require(!silent.isEnabled, "failed provider does not remain enabled")
  }

  // Native failure remains readable by settings/status after cleanup.
  let failing = main { profile(true, .disconnected) }
  main {
    failing.connection.disconnectError = NSError(domain: "ProviderLaunch", code: 77)
    failing.connection.onStart = { connection in
      connection.status = .connecting
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { connection.status = .disconnected }
    }
  }
  setup([failing], [])
  let failManager = main { NeoStationLocalTunnelManager.makeForTest() }
  let failed = ResultBox(), inspected = ResultBox()
  failManager.enableOwned(completion: failed.record)
  wait("failed startup", { failed.results.count == 1 })
  failManager.status(completion: inspected.record)
  wait("read error status", { inspected.results.count == 1 })
  main {
    require(inspected.success?["lastErrorCode"] as? String == "local_tunnel_start_failed", "localized error code retained")
    require((inspected.success?["lastErrorDetail"] as? String)?.contains("ProviderLaunch(77)") == true, "native diagnostic is not empty")
  }
  print("PASS: build269 mixed intents, own adoption, ordered handoff, one retry, IPC proof, retained native error")
  exit(0)
}
dispatchMain()
'''

PROVIDER_TESTS = r'''
extension PacketTunnelProvider {
  func flushEffects() { watchdogQueue.sync {} }
  func tick(_ elapsed: TimeInterval) {
    watchdogQueue.sync { expireHeartbeatIfNeeded(now: lastHeartbeatUptime + elapsed) }
  }
}
let delayed = PacketTunnelProvider()
delayed.startTunnel(options: nil) { require($0 == nil, "settings accepted") }
delayed.flushEffects(); delayed.settingsCallbacks[0](nil); delayed.flushEffects()
for elapsed in [5.0, 12, 24, 29.9] {
  delayed.tick(elapsed)
  require(delayed.cancels == 0, "provider survives initial iOS/host status delay")
}
var alive = false
delayed.handleAppMessage(Data("heartbeat".utf8)) { alive = $0 == Data("alive".utf8) }
delayed.flushEffects()
require(alive, "first real host heartbeat confirms handoff")
delayed.tick(4.999); require(delayed.cancels == 0, "normal heartbeat margin")
delayed.tick(5); require(delayed.cancels == 1, "normal force-kill watchdog restored")
let abandoned = PacketTunnelProvider()
abandoned.startTunnel(options: nil) { require($0 == nil, "settings accepted") }
abandoned.flushEffects(); abandoned.settingsCallbacks[0](nil); abandoned.flushEffects()
abandoned.tick(30)
require(abandoned.cancels == 1, "startup without a host is still bounded")
var revived = false
abandoned.handleAppMessage(Data("heartbeat".utf8)) { revived = $0 != nil }
abandoned.flushEffects(); require(!revived, "late heartbeat cannot revive expired startup")
print("PASS: build269 startup grace, first heartbeat transition, five-second normal watchdog, bounded orphan expiry")
'''



def check_native_dispatch():
    """Compile the production Flutter handler, replacing only platform effects."""
    bridge = (ROOT / 'packages/stikjit_bridge/ios/Classes/StikjitBridgePlugin.swift').read_text()
    begin = bridge.index('  public func handle(')
    end = bridge.index('    guard call.method == "enableMeloNxJit"', begin)
    handler = bridge[begin:end] + '    result(FlutterError(code: "unsupported", message: nil, details: nil))\n  }\n'
    harness = r'''
import Foundation
public struct FlutterMethodCall { let method: String; let arguments: Any? }
public typealias FlutterResult = (Any?) -> Void
struct FlutterError { let code: String; let message: String?; let details: Any? }
enum RouteFailure: Error {
  case failed
  var code: String { "test_failure" }
  var localizedDescription: String { "test failure" }
}
final class NeoStationLocalTunnelManager {
  static let shared = NeoStationLocalTunnelManager()
  typealias Response = Result<[String: Any], RouteFailure>
  var calls = [String]()
  var fail = false
  func reply(_ name: String, _ completion: (Response) -> Void) {
    calls.append(name)
    completion(fail ? .failure(.failed) : .success(["operation": name]))
  }
  func ensureRunning(completion: (Response) -> Void) { reply("automatic", completion) }
  func enableOwned(completion: (Response) -> Void) { reply("owned", completion) }
  func status(completion: (Response) -> Void) { reply("status", completion) }
  func disable(completion: (Response) -> Void) { reply("disable", completion) }
  func beginDebuggerLease(completion: (Response) -> Void) { reply("leaseBegin", completion) }
  func endDebuggerLease(token: String, completion: (Response) -> Void) { reply("leaseEnd", completion) }
}
final class ProductionHandler {
/* HANDLER */
}
let handler = ProductionHandler()
let manager = NeoStationLocalTunnelManager.shared
let token = "00000000-0000-4000-8000-000000000001"
for (method, operation) in [
  ("activateOwnedTunnel", "owned"), ("ensureLocalTunnel", "automatic"),
  ("localTunnelStatus", "status"), ("disableLocalTunnel", "disable"),
  ("beginDebuggerLease", "leaseBegin"), ("endDebuggerLease", "leaseEnd")
] {
  for failing in [false, true] {
    manager.calls = []; manager.fail = failing
    var results = [Any?]()
    handler.handle(FlutterMethodCall(method: method, arguments: ["token": token])) { results.append($0) }
    precondition(manager.calls == [operation], "dispatch must call only its own operation once")
    precondition(results.count == 1, "Flutter result must complete exactly once")
    if failing { precondition((results[0] as? FlutterError)?.code == "local_tunnel_test_failure") }
    else { precondition((results[0] as? [String: String])?["operation"] == operation) }
  }
}
print("PASS: build269 production Flutter-native dispatch compiles; explicit ON and automatic routing remain distinct")
'''.replace('/* HANDLER */', handler)
    print(transport.run_swift(harness, 'PASS: build269'))


def main():
    before = [M.read_bytes(), P.read_bytes()]
    subprocess.run(['python3', str(ROOT / 'build-utils/patch_local_tunnel_build269.py')], check=True)
    assert before == [M.read_bytes(), P.read_bytes()], 'Current patch must be idempotent'
    manager, provider = M.read_text(), P.read_text()
    check_native_dispatch()
    print(transport.check_manager_transport(manager, scenarios=HELPERS + SCENARIOS, marker='PASS: build269'))
    source = provider.replace('import NetworkExtension\n', '').replace('import os.log\n', '')
    print(transport.run_swift(transport.PROVIDER_PLATFORM + source + PROVIDER_TESTS, 'PASS: build269'))
    print(check_state_machine(manager))  # Retains all original queue/transport/packet tests.
    # The intent and running-state APIs used by the UI are exercised in Dart.
    ui = (ROOT / 'lib/screens/settings_screen/new_settings_options/tools_settings_content.dart').read_text()
    assert 'return state?.canStopOwnedTunnel ?? false;' in ui
    assert 'previous = await LocalJitTunnelService.status();' in ui
    toggle = ui.split('Future<void> _toggleTunnel()', 1)[1].split('Future<void> _refreshPairingState()', 1)[0]
    assert 'final disable = _shouldDisableTunnel(previous);' in toggle
    assert toggle.count('disable = _shouldDisableTunnel(previous);') == 1, 'Native status must not invert the displayed button action'
    assert toggle.index('final disable =') < toggle.index('await LocalJitTunnelService.status()')
    assert '_tunnelState!.lastErrorDetail!' in ui
    assert 'LocalJitDebuggerLease' in (ROOT / 'lib/services/rpcs3_internal_service.dart').read_text()
    assert 'subnetMasks: ["255.255.255.0"]' in provider
    assert 'NEIPv4Route(destinationAddress: peerAddress, subnetMask: "255.255.255.255")' in provider
    print('PASS: build269 UI uses live connection state, manual route intent and nonempty diagnostics')


if __name__ == '__main__':
    main()
