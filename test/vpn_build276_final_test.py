#!/usr/bin/env python3
"""Build 276 VPN/RPCS3 separation contract and deterministic manager tests."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'test'))
import local_jit_transport_behavior_test as old

manager_path = ROOT / 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
provider_path = ROOT / 'native/local_jit_tunnel/PacketTunnelProvider.swift'
dart_path = ROOT / 'packages/stikjit_bridge/lib/stikjit_bridge.dart'
service_path = ROOT / 'lib/services/rpcs3_internal_service.dart'

manager_source = manager_path.read_text()
provider_source = provider_path.read_text()
dart_source = dart_path.read_text()
rpcs3_service = service_path.read_text()

assert 'NEOSTATION_VPN_FINAL_276' in manager_source
assert 'NEOSTATION_VPN_MANUAL_ONLY_273' in manager_source

manual = manager_source.split('  func enableOwned(', 1)[1].split('  func status(', 1)[0]
assert 'probeJitRoute' not in manual
assert 'routeVerified: false' in manager_source

verify = manager_source.split('  private func verify(', 1)[1].split('  private func stopNext(', 1)[0]
assert 'probeJitRoute' not in verify
assert 'NEOSTATION_VPN_FINAL_276: system tunnel accepted independently of RemotePairing' in verify

fail = manager_source.split('  private func fail(', 1)[1].split('  private func summary(', 1)[0]
assert 'where !Self.isActive(manager.connection.status)' in fail

preflight = manager_source.split('  func ensureRunning(', 1)[1].split('  // Explicit Settings ON', 1)[0]
assert 'probeJitRoute' in preflight
for forbidden in ('startVPNTunnel', 'stopVPNTunnel', 'saveToPreferences', 'loadAllFromPreferences'):
    assert forbidden not in preflight, forbidden

assert 'subnetMasks: ["255.255.255.255"]' in provider_source
assert 'destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255"' in provider_source
assert 'settings.mtu = 1500' not in provider_source
assert 'network settings callback missing after 10s' not in provider_source
assert 'cancelTunnelWithError' not in provider_source
assert 'NEOSTATION_VPN_FINAL_276: packet backpressure' in provider_source

activate = dart_source.split('static Future<LocalJitTunnelState> activateOwnedTunnel()', 1)[1].split(
    '/// The native preflight proves endpoint reachability', 1
)[0]
assert 'routeVerified' not in activate
assert '!state.active || !state.managedByNeoStation' in activate

# Build 276 deliberately restores the device-tested Build 273 RPCS3/JIT host path.
assert 'RPCS3 JIT did not remain active after StikJIT detached.' in rpcs3_service
assert 'RPCS3 JIT did not remain active after the initial StikJIT attach.' not in rpcs3_service
assert 'Timer.periodic(const Duration(seconds: 1)' in rpcs3_service

for lifecycle in ('lib/main.dart', 'lib/widgets/app_lifecycle_handler.dart'):
    assert 'LocalJitTunnelService' not in (ROOT / lifecycle).read_text()

HELPERS = old.MANAGER_TESTS.split('DispatchQueue.global().async {', 1)[0]
HELPERS = HELPERS.replace('  func stopTestHeartbeat() { stopHeartbeat() }', '')

SCENARIOS = r'''
DispatchQueue.global().async {
  // 1. Manual ON succeeds without performing a RemotePairing probe.
  let owned = main { profile(true, .disconnected) }
  let external = main { profile(false, .connected) }
  let controller = main { NeoStationLocalTunnelManager.makeForTest() }
  setup([owned], [])
  let on = ResultBox()
  controller.enableOwned(completion: on.record)
  wait("manual ON without RemotePairing", { on.results.count == 1 })
  main {
    require(on.success != nil, "manual ON must not depend on RemotePairing")
    require(on.success?["managedByNeoStation"] as? Bool == true, "manual ON owns its profile")
    require(on.success?["active"] as? Bool == true, "system connected/connecting state is active")
    require(on.success?["routeVerified"] as? Bool == false, "manual ON does not claim JIT reachability")
    require(owned.connection.starts == 1, "manual ON starts once")
    require(owned.connection.stops == 0, "manual ON must never stop itself")
  }

  // 2. A later failed JIT route probe reports only a JIT error and cannot stop VPN.
  setup([owned], [false])
  let routeFailure = ResultBox()
  controller.ensureRunning(completion: routeFailure.record)
  wait("failed JIT route", { routeFailure.results.count == 1 })
  main {
    require(routeFailure.error?.code == "jit_route_unavailable", "failed route remains a JIT preflight error")
    require(owned.connection.stops == 0, "RemotePairing failure cannot turn VPN off")
    require(owned.connection.status == .connected, "VPN remains connected after failed route")
  }

  // 3. When RemotePairing becomes ready, the same already-running VPN is reused.
  setup([owned], [true])
  let routeReady = ResultBox()
  controller.ensureRunning(completion: routeReady.record)
  wait("ready JIT route", { routeReady.results.count == 1 })
  main {
    require(routeReady.success != nil, "ready route succeeds")
    require(owned.connection.starts == 1, "JIT probe never restarts VPN")
    require(owned.connection.stops == 0, "JIT probe never stops VPN")
  }

  // 4. Reasserting is still an active user tunnel and status is observational.
  main { owned.connection.status = .reasserting }
  setup([owned], [])
  let status = ResultBox()
  controller.status(completion: status.record)
  wait("reasserting status", { status.results.count == 1 })
  main {
    require(status.success?["active"] as? Bool == true, "reasserting must remain active")
    require(owned.connection.stops == 0, "status cannot mutate VPN")
  }

  // 5. LocalDevVPN remains a pure external route. NeoStation never stops/saves it.
  main { owned.connection.status = .disconnected; external.connection.status = .connected }
  setup([owned, external], [true])
  main { TestPlatform.signingFailure = .signingMissing }
  let externalRoute = ResultBox()
  controller.ensureRunning(completion: externalRoute.record)
  wait("LocalDevVPN route", { externalRoute.results.count == 1 })
  main {
    require(externalRoute.success?["managedByNeoStation"] as? Bool == false, "external route stays external")
    require(TestPlatform.loads == 0, "external route does not touch NetworkExtension preferences")
    require(external.connection.stops == 0 && external.saves == 0, "LocalDevVPN is never mutated")
  }

  // 6. Explicit OFF remains the only normal user stop path for NeoStation's profile.
  main { TestPlatform.signingFailure = nil; owned.connection.status = .connected }
  setup([owned, external], [])
  let off = ResultBox()
  controller.disable(completion: off.record)
  wait("explicit OFF", { off.results.count == 1 })
  main {
    require(off.success != nil, "explicit OFF completes")
    require(!owned.isEnabled, "explicit OFF persists disabled state")
    require(owned.connection.stops > 0, "explicit OFF is allowed to stop own tunnel")
    require(external.connection.stops == 0 && external.saves == 0, "explicit OFF still leaves LocalDevVPN alone")
  }

  print("PASS: Build 276 VPN lifecycle is independent of RemotePairing/RPCS3")
  exit(0)
}
dispatchMain()
'''

def main():
    manager = manager_source.replace('import Network\n', '').replace('import NetworkExtension\n', '')
    manager = old.replace_method(
        manager,
        '  private func providerBundleIdentifier()',
        '  private func providerBundleIdentifier() -> String? { "test.neostation.localtunnel" }',
    )
    manager = old.replace_method(
        manager,
        '  private static func signingCapabilityFailure()',
        '  private static func signingCapabilityFailure() -> NeoStationLocalTunnelError? { TestPlatform.signingFailure }',
    )
    manager = re.sub(
        r'(seconds: )(60|30|12|10|8|5|4)\b',
        lambda m: m[1] + str(float(m[2]) * 0.02),
        manager,
    )
    manager = manager.replace('seconds: TimeInterval = 5', 'seconds: TimeInterval = 0.1')
    manager = re.sub(
        r'(\.now\(\) \+ |systemUptime \+ )(60|30|12|10|8|5|4|1.5|0.5|0.2)\b',
        lambda m: m[1] + str(float(m[2]) * 0.02),
        manager,
    )
    manager = manager.replace(
        'routeProbeTimeout: TimeInterval = 1.25',
        'routeProbeTimeout: TimeInterval = 0.025',
    )

    platform = old.PLATFORM.replace(
        'require(String(data: data, encoding: .utf8) == "heartbeat", "heartbeat payload")',
        'require(String(data: data, encoding: .utf8) == "vpn271-status", "provider diagnostic payload")',
    )
    platform += '\nenum NeoStationVPNDiagnostics { static func record(_ a:String,_ b:String) {}\n static func snapshotRPCS3() {} }\n'

    print(old.run_swift(platform + manager + HELPERS + SCENARIOS, 'PASS: Build 276 VPN lifecycle'))

if __name__ == '__main__':
    main()
