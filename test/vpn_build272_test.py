#!/usr/bin/env python3
"""Test effective compiled sources and execute production Swift, not a VPN model.

NetworkExtension/NWConnection are replaced by deterministic effects; this is not
an iPhone integration or performance result. Native logging is tested on macOS.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'test'))
import vpn_build271_test as vpn
import local_jit_transport_behavior_test as swift

# Additional cases executed by the 271 production Swift harness. Its original
# manual cancellation, missing callbacks, packet pump and report tests stay on.
PURE_CASES = r'''
  for outcome: Bool? in [true, false, nil] {
    let owned = main { profile(true, .connected) }
    let foreign = main { profile(false, .connected) }
    let manager = main { NeoStationLocalTunnelManager.makeForTest() }
    setup([owned, foreign], [outcome])
    main {
      TestPlatform.holdLoads = true
      TestPlatform.signingFailure = .signingMissing
    }
    let probe = ResultBox()
    manager.ensureRunning(completion: probe.record)
    wait("pure TCP result including timeout", { probe.results.count == 1 })
    main {
      require((probe.success != nil) == (outcome == true), "probe result never changes the chosen VPN")
      require(TestPlatform.loads == 0, "TCP must not depend on our preferences")
      require(owned.connection.starts == 0 && owned.connection.stops == 0 && owned.saves == 0, "pure probe cannot mutate own VPN")
      require(foreign.connection.starts == 0 && foreign.connection.stops == 0 && foreign.saves == 0, "pure probe cannot mutate LocalDevVPN")
      require((owned.connection as! NETunnelProviderSession).messages == 0, "a game does not revalidate the provider")
    }
  }
  // Even a cached active manager and failed TCP must not go through verify(),
  // whose manual failure cleanup is allowed to stop a tunnel.
  let cached = main { profile(true, .disconnected) }
  let cachedManager = main { NeoStationLocalTunnelManager.makeForTest() }
  setup([cached], [true])
  let cachedOn = ResultBox()
  cachedManager.enableOwned(completion: cachedOn.record)
  wait("manual activation for cached case", { cachedOn.results.count == 1 })
  let counters = main { (cached.connection.starts, cached.connection.stops, cached.saves, (cached.connection as! NETunnelProviderSession).messages) }
  setup([cached], [false])
  let badProbe = ResultBox()
  cachedManager.ensureRunning(completion: badProbe.record)
  wait("failed probe against a cached internal tunnel", { badProbe.results.count == 1 })
  main {
    require(badProbe.error != nil && TestPlatform.loads == 0, "cached internal route still observes TCP first")
    require(counters.0 == cached.connection.starts && counters.1 == cached.connection.stops && counters.2 == cached.saves && counters.3 == (cached.connection as! NETunnelProviderSession).messages, "failed game preflight has zero control effects")
  }
  let cachedOff = ResultBox()
  cachedManager.disable(completion: cachedOff.record)
  wait("manual OFF", { cachedOff.results.count == 1 })
  setup([cached], [false])
  let afterOff = ResultBox()
  cachedManager.ensureRunning(completion: afterOff.record)
  wait("probe after manual OFF", { afterOff.results.count == 1 })
  main { require(!cached.isEnabled && cached.connection.status == .disconnected && cached.connection.starts == counters.0, "game does not undo manual OFF") }
  print("PASS: 272 TCP-first success/failure/deadline, inaccessible prefs, unsigned extension, cached route isolation and manual OFF persistence")
'''

HELPER_STUBS = r'''
import Foundation
struct NWParameters { static let tcp = NWParameters() }
enum NWEndpoint {
  struct Host { init(_ value: String) { precondition(value == "127.0.0.1") } }
  struct Port { init?(rawValue: UInt16) {} }
}
class NWConnection {
  enum State { case ready, failed(Error), waiting(Error), cancelled }
  enum Completion { case contentProcessed((Error?) -> Void) }
  static var events = [String]()
  var stateUpdateHandler: ((State) -> Void)?
  init(host: NWEndpoint.Host, port: NWEndpoint.Port, using: NWParameters) {}
  func start(queue: DispatchQueue) { queue.async { self.stateUpdateHandler?(.ready) } }
  func send(content: Data, completion: Completion) {
    let value = try! JSONSerialization.jsonObject(with: content) as! [String: Any]
    Self.events.append(value["event"] as! String)
    switch completion { case .contentProcessed(let callback): callback(nil) }
  }
  func cancel() {}
}
'''
HELPER_TESTS = r'''
private let reporter = try Rpcs3HelperReporter(port: 1234, token: "fixture-not-a-real-token")
try reporter.connect()
let start = ProcessInfo.processInfo.systemUptime
for _ in 0..<5000 { try reporter.send(event: "log", message: "optional") }
precondition(NWConnection.events.isEmpty)
precondition(ProcessInfo.processInfo.systemUptime-start < 1)
try reporter.send(event: "helper_connected", message: "connected")
try reporter.send(event: "pid_attached", message: "attached", targetPID: 42)
try reporter.send(event: "complete", message: "completed", success: true)
precondition(NWConnection.events == ["helper_connected", "pid_attached", "complete"])
reporter.close()
print("PASS: 272 optional helper logs perform no socket send; mandatory protocol events retained")
'''

# Exact hashes of effective 267/271 sources unrelated to the requested changes.
FROZEN = {'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm': '77b06f49b15bb5da20acd3780d23f21ecaaab6bfbb76fc602a66618df9b0594c', 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm': '71b087675468a565a1ce6370974192795353be77dd7e406242cc6371ccfb95da', 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h': 'd0d57c31c07d27a1277162d92a3644ee675a63863f9cfe70aa8f18537d79f98d', 'build-utils/patch_stikjit_rpcs3.py': 'ee6fb7e91a95aa158691d7933afc31d0de99012351dc81b00145af6c43eac7c3', 'build-utils/patch_stikjit_remote_pairing.py': 'bcfc80bed2abef8ccadd21a1b65dcc67642f07c767cf33b4157f3926f7b51a30', 'native/local_jit_tunnel/PacketTunnelProvider.swift': '2c7f9851a45863842ee5a21e6ed6b0543e4d1e94a5fc32b23eec8a5410d2bdde', 'build-utils/patch_rpcs3_build266_v09_core.py': 'ad0d7a7663987beabb80e93cb11e4be0d71951109788ca89026911837036c235', 'lib/services/dolphin_internal_v2_service.dart': 'd5c9ec72e5c6ca64186f9a4c22d49bacfb46711d87b276491f9f958230a91912', 'packages/dolphin_internal_bridge/ios/Classes/DolphinPerformanceOverlay.h': '9849bd45679ed8ec412f762ccdaf9e9e629709d3967f951ef9940ddd43b36d39', 'packages/dolphin_internal_bridge/ios/Classes/DolphinPerformanceOverlay.mm': '8367057e2596fc45646095d4603a080b7a79ce6043532d15bb08ac17e33c7409', 'packages/dolphin_internal_bridge/ios/Classes/DolphinRetroAchievementsAccount.mm': 'bf075f1a76a875305888d0c6dd011321a915568a79cf01d79f70e7ef1fc022a9', 'packages/dolphin_internal_bridge/ios/Classes/DolphinSessionLifecycle.mm': 'c296ca247fd56e00ed935d2107561848487fa2cb8f4ba863948bd18e801bc619', 'packages/dolphin_internal_bridge/ios/Classes/DolphinRecordingController.h': 'c5413437f2793e40c68eed661633a5dd0e6a786d8424e54a3aa682f66d1f4ff8', 'packages/dolphin_internal_bridge/ios/Classes/DolphinSessionMenu.mm': '0172bd00f7fc507f5e2bfd1a6016030ab8804484bc4b0e0fd8a303c5d311438b', 'packages/dolphin_internal_bridge/ios/Classes/DolphinInternalBridgePlugin.h': '90962fb801e0059fe55190408a638658b535d406cd2a827b289db9f5150f93ff', 'packages/dolphin_internal_bridge/ios/Classes/DolphinInternalBridgePlugin.mm': 'e89f7b1fdfabbc8a301d0e53303a453c3b04be6bf80b2aa6f0b5e77951099060', 'packages/dolphin_internal_bridge/ios/Classes/DolphinRecordingController.mm': '2754e9f3cc30db9870f89311fe358e46a8be4b08dd6e9c4680fef0a49edcbd38', 'packages/dolphin_internal_bridge/ios/Classes/DolphinRetroAchievementsAccount.h': 'b2b68dd6e01ebe8ce851d5089bb226fbb34bdd992a8afc6bb94fc15d4ad1bd0c', 'packages/dolphin_internal_bridge/ios/Classes/DolphinSessionLifecycle.h': 'a03b58d13ecc3b9646637bed4090b97ddd352a53efc1c4eb381a62f0e46d1274', 'packages/dolphin_internal_bridge/ios/Classes/DolphinSessionMenu.h': '382cf008fb78c5c93eaeb40a9c2de2453202318a98658b0a830118abcc1b2664', 'packages/dolphin_internal_bridge/ios/Classes/DolphinRecordingTimeline.h': 'f0c980b2215b17c7278827f55cd9f2c556097cf0d7a3c44a94acf3ddfddf628b'}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def contracts():
    for name, expected in FROZEN.items():
        assert digest(ROOT / name) == expected, 'Unrelated working source changed: ' + name
    manager = (ROOT / 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift').read_text()
    probe = manager.split('  func ensureRunning(', 1)[1].split('  func enableOwned(', 1)[0]
    for forbidden in ('loadForStart', 'begin(', 'verify(', 'Preferences', 'activeManager', 'fail(', 'route(owned'):
        assert forbidden not in probe, 'Mutation reachable from game entry: ' + forbidden
    assert 'self.probeJitRoute' in probe and '.routeUnavailable' in probe
    assert 'private func route(owned:' not in manager
    for method in ('probeJitRoute', 'externalRouteResponse'):
        fragment = manager.split('  private func ' + method, 1)[1].split('\n  private ', 1)[0]
        for mutation in ('startVPNTunnel', 'stopVPNTunnel', 'loadForStart', 'saveToPreferences', 'loadAllFromPreferences'):
            assert mutation not in fragment, method + ': ' + mutation
    service = (ROOT / 'lib/services/local_jit_tunnel_service.dart').read_text()
    game = service.split('ensureRunningForJit()', 1)[1].split('  /// Manual', 1)[0]
    assert 'StikjitBridge.ensureJitRoute()' in game
    for bad in ('_session', 'activateOwned', 'disableLocal', 'status()', 'owned:'):
        assert bad not in game
    for name in ('lib/main.dart', 'lib/widgets/app_lifecycle_handler.dart'):
        assert 'LocalJitTunnelService' not in (ROOT / name).read_text(), name
    policy = (ROOT / 'lib/services/local_jit_lifecycle_policy.dart').read_text()
    assert '=> false;' in policy
    runtime = (ROOT / 'lib/services/rpcs3_internal_service.dart').read_text()
    assert runtime.count('await LocalJitTunnelService.ensureRunningForJit();') == 1
    assert 'Timer.periodic' not in runtime and 'LocalJitDebuggerLease' not in runtime
    assert runtime.index('if (_initialized)') < runtime.index('await _attachJitForCore();')
    assert runtime.index('Rpcs3InternalBridge.initialize(') < runtime.index('Rpcs3InternalBridge.completeJit()')
    for token in ('expandedJitRegion: false', '_runtimePreparation', '_jitPreparation', 'requiresCoreHandshake', 'Rpcs3InternalBridge.preflight()'):
        assert token in runtime, 'Required JIT protection missing: ' + token
    helper = (ROOT / 'packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift').read_text()
    guard = '''    // NEOSTATION_RPCS3_OPTIONAL_LOGS_OFF_272. Never block StikJIT on diagnostics.
    // helper_connected, pid_attached and complete remain reliable and unchanged.
    if event == "log" { return }
'''
    normalized = helper.replace(guard, '')
    assert hashlib.sha256(normalized.encode()).hexdigest() == '70eb3be2822b3415709d5f9ca412227070b6eafe28ced60a652af7e2f807a4a0', 'Helper changed beyond optional logging'
    assert helper.index('if event == "log"') < helper.index('sendLock.lock()')
    logger = (ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h').read_text()
    for bad in ('synchronizeFile', 'fsync(', 'dispatch_sync(', '@synchronized'):
        assert bad not in logger
    assert 'dispatch_async(RPCS3DiagnosticQueue()' in logger and '>= 128' in logger
    provider = (ROOT / 'native/local_jit_tunnel/PacketTunnelProvider.swift').read_text()
    assert 'expireHeartbeat' not in provider and 'jitLease' not in provider
    assert 'startHeartbeat' not in manager and 'beginDebuggerLease' not in manager
    core_patch = (ROOT / 'build-utils/patch_rpcs3_build266_v09_core.py').read_text()
    assert 'not an offline compile of all' in core_patch
    output = ROOT / 'build/rpcs3-ci/build272-source-policy.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    sourcefiles = ('lib/services/rpcs3_internal_service.dart', 'lib/services/local_jit_tunnel_service.dart',
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h',
        'packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift',
        'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift')
    output.write_text(json.dumps({'build': 272, 'frozenSourceSHA256': FROZEN,
        'changedSourceSHA256': {name: digest(ROOT/name) for name in sourcefiles},
        'readOnlyPreflight': True, 'lifecycleVPNMutation': False,
        'baselineHelperUnchangedExceptOptionalLogs': True,
        'shaderCache': 'baseline retained; no newly-added whole-game precompile',
        'deviceTested': False}, indent=2) + '\n')
    return helper


def main():
    helper = contracts()
    vpn.SCENARIOS = vpn.SCENARIOS.replace('DispatchQueue.global().async {', 'DispatchQueue.global().async {' + PURE_CASES, 1)
    vpn.SCENARIOS = vpn.SCENARIOS.replace('setup([parallelProfile], [true])', 'setup([parallelProfile], [true, true])')
    # A probe must complete while the manual activation is still awaiting SAVE.
    vpn.SCENARIOS = vpn.SCENARIOS.replace('  main {}; main { parallelProfile.saveCallbacks.forEach',
        '  wait("probe independent of pending activation", { results.results.count == 1 })\n  main {}; main { parallelProfile.saveCallbacks.forEach')
    vpn.main()
    reporter = helper[helper.index('private final class Rpcs3HelperReporter'):]
    print(swift.run_swift(HELPER_STUBS + reporter + HELPER_TESTS, 'PASS: 272 optional'))
    print('PASS: 272 compiled-source separation, immutable baseline JIT/loader/Dolphin, bounded diagnostics; on-device testing still required')


if __name__ == '__main__':
    main()
