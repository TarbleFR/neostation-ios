#!/usr/bin/env python3
"""Build 273 VPN-only verification.

Runs the effective production manager against deterministic NetworkExtension
stubs. These tests prove policy separation and bounded behavior, not physical
iPhone VPN compatibility.
"""
from pathlib import Path
import re
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'test'))
import local_jit_transport_behavior_test as old

HELPERS=old.MANAGER_TESTS.split('DispatchQueue.global().async {',1)[0]
HELPERS=HELPERS.replace('  func stopTestHeartbeat() { stopHeartbeat() }','')

SCENARIOS=r'''
DispatchQueue.global().async {
  // External/LocalDev route works even if NeoStation preferences/signing are unavailable.
  let foreign = main { profile(false, .connected) }
  let observer = main { NeoStationLocalTunnelManager.makeForTest() }
  setup([foreign], [true])
  main {
    TestPlatform.signingFailure = .signingMissing
    TestPlatform.holdLoads = true
  }
  let reachable = ResultBox()
  observer.ensureRunning(completion: reachable.record)
  wait("reachable external route", { reachable.results.count == 1 })
  main {
    require(reachable.success?["managedByNeoStation"] as? Bool == false, "reachable route is observational")
    require(TestPlatform.loads == 0, "game probe must not read NetworkExtension preferences")
    require(foreign.saves == 0 && foreign.connection.starts == 0 && foreign.connection.stops == 0, "game probe cannot mutate LocalDevVPN")
  }

  // Failed TCP probe is an error only; it never falls back to NeoStation VPN.
  let owned = main { profile(true, .disconnected) }
  let failedObserver = main { NeoStationLocalTunnelManager.makeForTest() }
  setup([owned, foreign], [false])
  main {
    TestPlatform.signingFailure = nil
    TestPlatform.holdLoads = true
  }
  let unreachable = ResultBox()
  failedObserver.ensureRunning(completion: unreachable.record)
  wait("unreachable route", { unreachable.results.count == 1 })
  main {
    require(unreachable.error?.code == "jit_route_unavailable", "failed TCP remains a read-only failure")
    require(TestPlatform.loads == 0, "failed probe must not read preferences")
    require(owned.saves == 0 && owned.connection.starts == 0 && owned.connection.stops == 0, "failed probe cannot start or stop NeoStation VPN")
    require(foreign.saves == 0 && foreign.connection.starts == 0 && foreign.connection.stops == 0, "failed probe cannot touch LocalDevVPN")
  }

  // Explicit Settings ON is the only start path.
  let control = main { NeoStationLocalTunnelManager.makeForTest() }
  setup([owned, foreign], [true])
  main { TestPlatform.holdLoads = false }
  let on = ResultBox()
  control.enableOwned(completion: on.record)
  wait("manual ON", { on.results.count == 1 })
  main {
    require(on.success?["managedByNeoStation"] as? Bool == true, "manual ON selects own profile")
    require(owned.connection.starts == 1 && owned.isEnabled, "manual ON starts and persists own profile")
    require(!owned.isOnDemandEnabled, "on-demand takeover is forbidden")
    require(foreign.saves == 0 && foreign.connection.stops == 0, "NeoStation does not control another app profile")
  }

  // App relaunch/status is observational: no start/stop and persisted profile remains visible.
  let startsAfterOn = main { owned.connection.starts }
  let stopsAfterOn = main { owned.connection.stops }
  let savesAfterOn = main { owned.saves }
  let reopened = main { NeoStationLocalTunnelManager.makeForTest() }
  setup([owned, foreign], [])
  let persisted = ResultBox()
  reopened.status(completion: persisted.record)
  wait("reopened status", { persisted.results.count == 1 })
  main {
    require(persisted.success?["enabled"] as? Bool == true, "manual choice remains persisted")
    require(persisted.success?["active"] as? Bool == true, "active system tunnel remains visible after app relaunch")
    require(owned.connection.starts == startsAfterOn && owned.connection.stops == stopsAfterOn && owned.saves == savesAfterOn, "status cannot mutate persisted VPN")
  }

  // A later failed game probe must not tear down the manually selected VPN.
  setup([owned, foreign], [false])
  main { TestPlatform.holdLoads = true }
  let afterOnProbe = ResultBox()
  reopened.ensureRunning(completion: afterOnProbe.record)
  wait("failed probe after manual ON", { afterOnProbe.results.count == 1 })
  main {
    require(afterOnProbe.error?.code == "jit_route_unavailable", "probe reports failure only")
    require(TestPlatform.loads == 0, "probe stays preference-independent")
    require(owned.connection.starts == startsAfterOn && owned.connection.stops == stopsAfterOn && owned.saves == savesAfterOn, "game failure cannot change user VPN choice")
  }

  // Explicit Settings OFF is the only stop path.
  main { TestPlatform.holdLoads = false }
  setup([owned, foreign], [])
  let off = ResultBox()
  reopened.disable(completion: off.record)
  wait("manual OFF", { off.results.count == 1 })
  main {
    require(off.success != nil && !owned.isEnabled, "manual OFF persists disabled state")
    require(foreign.saves == 0 && foreign.connection.stops == 0, "manual OFF touches own profile only")
  }

  // LocalDevVPN remains usable after own profile is OFF and preferences are unreadable.
  setup([owned, foreign], [true])
  main {
    TestPlatform.holdLoads = true
    TestPlatform.signingFailure = .signingMissing
  }
  let localDev = ResultBox()
  reopened.ensureRunning(completion: localDev.record)
  wait("LocalDev after own OFF", { localDev.results.count == 1 })
  main {
    require(localDev.success != nil, "LocalDev route works independently of own profile access")
    require(TestPlatform.loads == 0, "LocalDev route still probes before preferences")
    require(!owned.isEnabled, "read-only probe cannot re-enable own VPN")
  }

  print("PASS: 273 manual-only VPN, TCP-first observation, persistent user choice, no game/lifecycle mutation")
  exit(0)
}
dispatchMain()
'''

def main():
    manager_path=ROOT/'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
    manager=manager_path.read_text()
    assert 'NEOSTATION_VPN_MANUAL_ONLY_273' in manager
    preflight=manager.split('  func ensureRunning(',1)[1].split('  // Explicit Settings ON',1)[0]
    assert 'probeJitRoute' in preflight
    for forbidden in (
        'loadForStart','begin(','verify(','activeManager','NETunnelProviderManager',
        'startVPNTunnel','stopVPNTunnel','saveToPreferences','loadAllFromPreferences',
    ):
        assert forbidden not in preflight, 'game preflight can mutate VPN: '+forbidden
    assert 'manager.isOnDemandEnabled = false' in manager

    service=(ROOT/'lib/services/local_jit_tunnel_service.dart').read_text()
    game=service.split('ensureRunningForJit()',1)[1].split('  /// Explicit Settings action only.',1)[0]
    assert 'StikjitBridge.ensureJitRoute()' in game
    for forbidden in ('activateOwnedTunnel','disableLocalTunnel','localTunnelStatus'):
        assert forbidden not in game
    assert 'authorizeAndEnable()' in service and 'StikjitBridge.activateOwnedTunnel()' in service
    assert 'disable()' in service and 'StikjitBridge.disableLocalTunnel()' in service

    for name in ('lib/main.dart','lib/widgets/app_lifecycle_handler.dart'):
        assert 'LocalJitTunnelService' not in (ROOT/name).read_text(), name+' still controls VPN lifecycle'
    assert '=> false;' in (ROOT/'lib/services/local_jit_lifecycle_policy.dart').read_text()

    ui=(ROOT/'lib/screens/settings_screen/new_settings_options/tools_settings_content.dart').read_text()
    toggle=ui.split('Future<void> _toggleTunnel()',1)[1].split('Future<void> _refreshPairingState()',1)[0]
    assert 'LocalJitTunnelService.authorizeAndEnable()' in toggle
    assert 'LocalJitTunnelService.disable()' in toggle

    # Preserve effective Build 267/271 RPCS3/JIT baseline: this patch itself has no references to those files.
    patch=(ROOT/'build-utils/patch_vpn_build273.py').read_text()
    for forbidden in (
        "write('lib/services/rpcs3_internal_service.dart'",
        "write('packages/rpcs3_jit_helper",
        "write('packages/rpcs3_internal_bridge",
        "write('native/local_jit_tunnel/PacketTunnelProvider.swift'",
        "write('packages/dolphin_internal_bridge",
    ):
        assert forbidden not in patch, 'VPN-only patch unexpectedly modifies runtime: '+forbidden

    manager=manager.replace('import Network\n','').replace('import NetworkExtension\n','')
    manager=old.replace_method(manager,'  private func providerBundleIdentifier()', '''  private func providerBundleIdentifier() -> String? { "test.neostation.localtunnel" }''')
    manager=old.replace_method(manager,'  private static func signingCapabilityFailure()', '''  private static func signingCapabilityFailure() -> NeoStationLocalTunnelError? { TestPlatform.signingFailure }''')
    manager=re.sub(r'(seconds: )(30|12|10|5|4)\b',lambda m:m[1]+str(float(m[2])*0.02),manager)
    manager=manager.replace('seconds: TimeInterval = 5','seconds: TimeInterval = 0.1')
    manager=re.sub(r'(\.now\(\) \+ |systemUptime \+ )(12|10|5|4|1.5|0.5|0.2)\b',lambda m:m[1]+str(float(m[2])*0.02),manager)
    manager=manager.replace('routeProbeTimeout: TimeInterval = 1.25','routeProbeTimeout: TimeInterval = 0.025')

    platform=old.PLATFORM
    platform=platform.replace(
        'responseHandler?(acknowledgeHeartbeat ? Data("alive".utf8) : nil)',
        '''responseHandler?(acknowledgeHeartbeat ? try! JSONSerialization.data(withJSONObject:["version":271,"ready":true]) : nil)''',
    )
    platform=platform.replace(
        '''    completionHandler(TestPlatform.managers, nil)''',
        '''    if TestPlatform.holdLoads { TestPlatform.loadCallbacks.append(completionHandler) }
    else { completionHandler(TestPlatform.managers, nil) }''',
    )
    platform=platform.replace('  var holdSaves = false','  var holdSaves = false\n  var holdReload = false\n  var reloadCallbacks = [(Error?) -> Void]()')
    platform=platform.replace(
        'func loadFromPreferences(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }',
        'func loadFromPreferences(completionHandler: @escaping (Error?) -> Void) { if holdReload { reloadCallbacks.append(completionHandler) } else { completionHandler(nil) } }',
    )
    platform=platform.replace(
        '  static var loads = 0',
        '  static var loads = 0\n  static var holdLoads = false\n  static var loadCallbacks = [([NETunnelProviderManager]?, Error?) -> Void]()',
    )
    platform+='\nenum NeoStationVPNDiagnostics { static func record(_ a:String,_ b:String) {}\n static func snapshotRPCS3() {} }\n'

    helpers=HELPERS.replace(
        'TestPlatform.signingFailure = nil; TestPlatform.loads = 0',
        'TestPlatform.signingFailure = nil; TestPlatform.loads = 0; TestPlatform.holdLoads = false; TestPlatform.loadCallbacks=[]',
    )
    print(old.run_swift(platform+manager+helpers+SCENARIOS,'PASS: 273 manual-only VPN'))
    print('PASS: 273 source policy separation; physical-device NetworkExtension behavior still requires iPhone testing')

if __name__=='__main__':
    main()
