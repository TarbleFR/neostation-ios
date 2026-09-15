#!/usr/bin/env python3
"""Execute production Swift transport/provider logic with simulated iOS effects.

Only platform imports, installed-bundle capability checks, network/NE objects
and test durations are replaced. Queue, polling, route selection, cleanup,
packet reflection and cancellation code are the actual production methods.
These are NOT iPhone integration tests or performance measurements.
"""
from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANAGER = ROOT / 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
PROVIDER = ROOT / 'native/local_jit_tunnel/PacketTunnelProvider.swift'


def run_swift(text: str, marker: str) -> str:
    swift = shutil.which('swift')
    if not swift:
        raise AssertionError('Swift is required for executable transport tests')
    with tempfile.TemporaryDirectory(prefix='neostation-transport-') as temp:
        source = Path(temp) / 'Tests.swift'
        source.write_text(text)
        result = subprocess.run(
            [swift, '-swift-version', '5', str(source)], text=True,
            capture_output=True, timeout=45, check=False,
        )
    if result.returncode or marker not in result.stdout:
        raise AssertionError(f'Swift checks failed:\n{result.stdout}\n{result.stderr}')
    return result.stdout.strip()


def replace_method(text: str, signature: str, replacement: str) -> str:
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if text[end] == '{':
            depth += 1
        elif text[end] == '}':
            depth -= 1
        end += 1
    return text[:start] + replacement + text[end:]


PLATFORM = r'''
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
func require(_ condition: Bool, _ message: String) {
  if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
enum NEVPNStatus { case invalid, disconnected, connecting, connected, reasserting, disconnecting }
let NEVPNErrorDomain = "NEVPNErrorDomain"
enum NEVPNError: Int { case configurationReadWriteFailed = 5 }
class NEVPNProtocol {}
class NETunnelProviderProtocol: NEVPNProtocol {
  var providerBundleIdentifier: String?
  var providerConfiguration: [String: Any]?
  var serverAddress: String?
}
class NEVPNConnection {
  private let lock = NSLock()
  private var rawStatus: NEVPNStatus = .disconnected
  var status: NEVPNStatus {
    get { lock.lock(); defer { lock.unlock() }; return rawStatus }
    set { lock.lock(); rawStatus = newValue; lock.unlock() }
  }
  var starts = 0
  var stops = 0
  var startError: Error?
  var disconnectError: Error?
  var errorRequests = 0
  var holdError = false
  var errorCallbacks = [(Error?) -> Void]()
  var onStart: ((NEVPNConnection) -> Void)?
  var onStop: ((NEVPNConnection) -> Void)?
  func startVPNTunnel(options: [String: NSObject]?) throws {
    starts += 1
    if let error = startError { throw error }
    if let action = onStart { action(self) } else { status = .connected }
  }
  func stopVPNTunnel() {
    stops += 1
    if let action = onStop { action(self) } else { status = .disconnected }
  }
  func fetchLastDisconnectError(completionHandler: @escaping (Error?) -> Void) {
    errorRequests += 1
    if holdError { errorCallbacks.append(completionHandler) }
    else { completionHandler(disconnectError) }
  }
}
class NETunnelProviderSession: NEVPNConnection {
  private let messageLock = NSLock()
  private var messageCount = 0
  var messages: Int { messageLock.lock(); defer { messageLock.unlock() }; return messageCount }
  func sendProviderMessage(_ data: Data, responseHandler: ((Data?) -> Void)?) throws {
    require(String(data: data, encoding: .utf8) == "heartbeat", "heartbeat payload")
    messageLock.lock(); messageCount += 1; messageLock.unlock()
    responseHandler?(Data("alive".utf8))
  }
}
final class NETunnelProviderManager {
  var protocolConfiguration: NEVPNProtocol? = NETunnelProviderProtocol()
  var localizedDescription: String?
  var isEnabled = false
  var isOnDemandEnabled = false
  var onDemandRules = [String]()
  let connection: NEVPNConnection = NETunnelProviderSession()
  var saves = 0
  var removals = 0
  var holdSaves = false
  var saveError: Error?
  var saveCallbacks = [(Error?) -> Void]()
  var persisted = [(Bool, Bool, Int)]()
  static func loadAllFromPreferences(completionHandler: @escaping ([NETunnelProviderManager]?, Error?) -> Void) {
    TestPlatform.loads += 1
    completionHandler(TestPlatform.managers, nil)
  }
  func saveToPreferences(completionHandler: @escaping (Error?) -> Void) {
    saves += 1
    persisted.append((isEnabled, isOnDemandEnabled, onDemandRules.count))
    if holdSaves { saveCallbacks.append(completionHandler) }
    else { completionHandler(saveError) }
  }
  func loadFromPreferences(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
  func removeFromPreferences(completionHandler: @escaping (Error?) -> Void) {
    removals += 1; completionHandler(nil)
  }
}
enum NWEndpoint {
  struct Host { init(_ address: String) { require(address == "10.7.0.1", "real peer address") } }
  struct Port { init?(rawValue: UInt16) { require(rawValue == 49152, "real pairing port") } }
}
struct NWParameters { static let tcp = NWParameters() }
final class NWConnection {
  enum State { case ready, failed, cancelled, waiting }
  var stateUpdateHandler: ((State) -> Void)?
  let outcome: Bool?
  init(host: NWEndpoint.Host, port: NWEndpoint.Port, using: NWParameters) {
    require(!TestPlatform.probes.isEmpty, "every route probe must be expected by the test")
    outcome = TestPlatform.probes.removeFirst()
  }
  func start(queue: DispatchQueue) {
    queue.async {
      if let outcome = self.outcome { self.stateUpdateHandler?(outcome ? .ready : .failed) }
    }
  }
  func cancel() {}
}
enum TestPlatform {
  static var managers = [NETunnelProviderManager]()
  static var probes = [Bool?]()
  static var signingFailure: NeoStationLocalTunnelError?
  static var loads = 0
}
'''

MANAGER_TESTS = r'''
extension NeoStationLocalTunnelManager {
  static func makeForTest() -> NeoStationLocalTunnelManager { NeoStationLocalTunnelManager() }
  func stopTestHeartbeat() { stopHeartbeat() }
}
func main<T>(_ body: () -> T) -> T { DispatchQueue.main.sync(execute: body) }
func wait(_ label: String, _ condition: @escaping () -> Bool) {
  let deadline = ProcessInfo.processInfo.systemUptime + 3
  while !main(condition) {
    require(ProcessInfo.processInfo.systemUptime < deadline, "timed out: \(label)")
    Thread.sleep(forTimeInterval: 0.002)
  }
}
func profile(_ owned: Bool, _ status: NEVPNStatus) -> NETunnelProviderManager {
  let value = NETunnelProviderManager()
  let configuration = NETunnelProviderProtocol()
  configuration.providerBundleIdentifier = owned ? "test.neostation.localtunnel" : "external.localdevvpn"
  value.protocolConfiguration = configuration
  value.localizedDescription = owned ? "NeoStation Local JIT Tunnel" : "LocalDevVPN"
  value.connection.status = status
  return value
}
final class ResultBox {
  var results = [NeoStationLocalTunnelManager.Response]()
  func record(_ result: NeoStationLocalTunnelManager.Response) { results.append(result) }
  var success: [String: Any]? {
    guard let result = results.last, case .success(let value) = result else { return nil }
    return value
  }
  var error: NeoStationLocalTunnelError? {
    guard let result = results.last, case .failure(let value) = result else { return nil }
    return value
  }
}
func setup(_ managers: [NETunnelProviderManager], _ probes: [Bool?]) {
  main {
    TestPlatform.managers = managers; TestPlatform.probes = probes
    TestPlatform.signingFailure = nil; TestPlatform.loads = 0
  }
}
DispatchQueue.global().async {
  // A: both VPNs off -> one owned start and a successful REAL probe.
  let owned = main { profile(true, .disconnected) }
  let external = main { profile(false, .connected) }
  let manager = main { NeoStationLocalTunnelManager.makeForTest() }
  setup([owned], [false, true])
  let first = ResultBox()
  manager.ensureRunning(completion: first.record)
  wait("owned route", { !first.results.isEmpty })
  main {
    require(first.success?["managedByNeoStation"] as? Bool == true, "owned route ownership")
    require(first.success?["routeVerified"] as? Bool == true, "TCP verification distinct from VPN status")
    require(owned.connection.starts == 1, "one owned start")
    require(!owned.isOnDemandEnabled && owned.onDemandRules.isEmpty, "no On-Demand")
    // Heartbeats must continue while the main queue is occupied by native work.
    let session = owned.connection as! NETunnelProviderSession
    let before = session.messages
    Thread.sleep(forTimeInterval: 0.045)
    require(session.messages > before, "heartbeat is independent of the main queue")
  }
  let stopped = ResultBox()
  manager.disable(completion: stopped.record)
  wait("manual stop", { !stopped.results.isEmpty })
  main {
    require(stopped.success?["active"] as? Bool == false, "stop returns inactive")
    require(!owned.isEnabled && !owned.isOnDemandEnabled && owned.onDemandRules.isEmpty, "disabled profile persisted")
  }

  // B: working external route wins even without our signing capability.
  setup([owned, external], [true])
  main { TestPlatform.signingFailure = .signingMissing }
  let extResult = ResultBox()
  manager.ensureRunning(completion: extResult.record)
  wait("external route", { !extResult.results.isEmpty })
  main {
    require(extResult.success?["managedByNeoStation"] as? Bool == false, "external route reused")
    require(TestPlatform.loads == 0, "external route independent of profile permission")
    require(external.saves == 0 && external.connection.stops == 0, "external profile untouched")
  }
  let externalStop = ResultBox()
  manager.disable(completion: externalStop.record)
  wait("stop leaves external intact", { !externalStop.results.isEmpty })
  main { require(external.connection.stops == 0 && external.saves == 0, "never stop or save LocalDevVPN") }

  // C/H: after USER turns off LocalDevVPN, a fresh request can start our tunnel.
  main { external.connection.status = .disconnected }
  setup([owned, external], [false, true])
  let resumed = ResultBox()
  manager.ensureRunning(completion: resumed.record)
  wait("external-to-owned handoff", { !resumed.results.isEmpty })
  main {
    require(resumed.success?["managedByNeoStation"] as? Bool == true, "handoff to owned route")
    require(owned.connection.starts == 2, "new legitimate start after stop")
    manager.stopTestHeartbeat()
  }

  // D: incompatible loaded manager is never modified and never fakes success.
  let blockedManager = main { NeoStationLocalTunnelManager.makeForTest() }
  main { external.connection.status = .connected }
  setup([external], [false])
  let blocked = ResultBox()
  blockedManager.ensureRunning(completion: blocked.record)
  wait("incompatible route", { !blocked.results.isEmpty })
  main {
    require(blocked.error?.code == "vpn_conflict", "incompatible VPN is a failure")
    require(external.saves == 0 && external.connection.stops == 0, "conflict must not mutate external VPN")
  }

  // An owned disconnecting transition must finish BEFORE startVPNTunnel.
  let draining = main { profile(true, .disconnecting) }
  let handoff = main { NeoStationLocalTunnelManager.makeForTest() }
  setup([draining], [false, true])
  let drainResult = ResultBox()
  handoff.ensureRunning(completion: drainResult.record)
  wait("waiting for disconnect", { draining.saves > 0 })
  Thread.sleep(forTimeInterval: 0.012)
  main {
    require(draining.connection.starts == 0, "no start while disconnecting")
    draining.connection.status = .disconnected
  }
  wait("start after disconnect", { !drainResult.results.isEmpty })
  main {
    require(drainResult.success != nil && draining.connection.starts == 1, "start after observed disconnect")
    handoff.stopTestHeartbeat()
  }

  // Terminal startup failure preserves the native error and neutralizes profile.
  let failing = main { profile(true, .disconnected) }
  main {
    failing.connection.disconnectError = NSError(domain: "TestProvider", code: 54)
    failing.connection.onStart = { connection in
      connection.status = .connecting
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { connection.status = .disconnected }
    }
  }
  setup([failing], [false])
  let failingManager = main { NeoStationLocalTunnelManager.makeForTest() }
  let failure = ResultBox()
  failingManager.ensureRunning(completion: failure.record)
  wait("provider failure", { !failure.results.isEmpty })
  main {
    require(failure.error?.code == "start_failed", "terminal disconnect is not a generic timeout")
    require(failure.error?.localizedDescription.contains("TestProvider(54)") == true, "native domain and code retained")
    require(!failing.isEnabled && failing.connection.stops >= 1, "failure stops and disables profile")
  }

  // Timeout is bounded, queried once, cleaned up, with late callbacks ignored.
  let timeoutProfile = main { profile(true, .disconnected) }
  main {
    timeoutProfile.connection.onStart = { $0.status = .connecting }
    timeoutProfile.connection.holdError = true
  }
  setup([timeoutProfile], [false])
  let timeoutManager = main { NeoStationLocalTunnelManager.makeForTest() }
  let timedOut = ResultBox()
  timeoutManager.ensureRunning(completion: timedOut.record)
  wait("bounded timeout", { !timedOut.results.isEmpty })
  main {
    require(timedOut.error?.code == "connection_timeout", "connection timeout code retained")
    require(!timeoutProfile.isEnabled && timeoutProfile.connection.stops >= 1, "no late activation left enabled")
    require(timeoutProfile.connection.errorRequests == 1, "disconnect diagnostic fetched once")
    for callback in timeoutProfile.connection.errorCallbacks { callback(NSError(domain: "Late", code: 1)) }
  }
  Thread.sleep(forTimeInterval: 0.025)
  main { require(timedOut.results.count == 1, "late diagnostics settle the operation only once") }

  // F/G: stop/start/stop invalidates a queued resume during preference saving.
  let held = main { profile(true, .disconnected) }
  main { held.holdSaves = true }
  setup([held], [false])
  let racing = main { NeoStationLocalTunnelManager.makeForTest() }
  let old = ResultBox(), queued = ResultBox(), stops = ResultBox()
  racing.ensureRunning(completion: old.record)
  wait("held save", { held.saveCallbacks.count == 1 })
  racing.disable(completion: stops.record)
  racing.ensureRunning(completion: queued.record)
  racing.disable(completion: stops.record)
  wait("obsolete resume cancelled", { queued.results.count == 1 })
  main {
    held.holdSaves = false
    let callbacks = held.saveCallbacks; held.saveCallbacks.removeAll()
    callbacks.forEach { $0(nil) }
  }
  wait("both stops completed", { stops.results.count == 2 })
  main {
    require(old.error?.code == "cancelled" && queued.error?.code == "cancelled", "both stale starts cancelled")
    require(held.connection.starts == 0, "no obsolete start after stop")
    require(!held.isEnabled && !held.isOnDemandEnabled, "stop wins profile persistence")
  }
  // Parallel fresh preflights share one activation and every caller completes.
  setup([held], [false, true])
  let parallel = ResultBox()
  for _ in 0..<3 { racing.ensureRunning(completion: parallel.record) }
  wait("coalesced preflights", { parallel.results.count == 3 })
  main {
    require(parallel.results.allSatisfy { if case .success = $0 { return true }; return false }, "all fresh callers succeed")
    require(held.connection.starts == 1, "fresh concurrent requests coalesce")
    racing.stopTestHeartbeat()
  }
  print("PASS: transport scenarios A-H, external ownership, real probe, disconnect transition, terminal error, timeout cleanup, late callback, heartbeat queue")
  exit(0)
}
dispatchMain()
'''

PROVIDER_PLATFORM = r'''
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
func require(_ condition: Bool, _ message: String) {
  if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
enum Privacy { case `public` }
struct LogMessage: ExpressibleByStringInterpolation {
  init(stringLiteral value: String) {}
  init(stringInterpolation: StringInterpolation) {}
  struct StringInterpolation: StringInterpolationProtocol {
    init(literalCapacity: Int, interpolationCount: Int) {}
    mutating func appendLiteral(_ text: String) {}
    mutating func appendInterpolation<T>(_ value: T) {}
    mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) {}
  }
}
struct Logger {
  init(subsystem: String, category: String) {}
  func info(_ message: LogMessage) {}
  func error(_ message: LogMessage) {}
}
class NEVPNProtocol {}
class NETunnelProviderProtocol: NEVPNProtocol { var providerConfiguration: [String: Any]? }
class NEIPv4Route {
  init(destinationAddress: String, subnetMask: String) {}
  static func `default`() -> NEIPv4Route { NEIPv4Route(destinationAddress: "0", subnetMask: "0") }
}
class NEIPv4Settings {
  var includedRoutes = [NEIPv4Route]()
  var excludedRoutes = [NEIPv4Route]()
  init(addresses: [String], subnetMasks: [String]) {}
}
class NEPacketTunnelNetworkSettings {
  var ipv4Settings: NEIPv4Settings?
  var mtu = 0
  init(tunnelRemoteAddress: String) {}
}
enum NEProviderStopReason: Int { case userInitiated = 1 }
class TestPacketFlow {
  var readers = [([Data], [NSNumber]) -> Void]()
  var writes = [[Data]]()
  func readPackets(completionHandler: @escaping ([Data], [NSNumber]) -> Void) { readers.append(completionHandler) }
  func writePackets(_ packets: [Data], withProtocols: [NSNumber]) { writes.append(packets) }
}
class NEPacketTunnelProvider {
  let packetFlow = TestPacketFlow()
  let protocolConfiguration: NEVPNProtocol = NETunnelProviderProtocol()
  var settingsCallbacks = [(Error?) -> Void]()
  var cancels = 0
  func setTunnelNetworkSettings(_ settings: NEPacketTunnelNetworkSettings, completionHandler: @escaping (Error?) -> Void) {
    settingsCallbacks.append(completionHandler)
  }
  func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {}
  func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {}
  func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {}
  func cancelTunnelWithError(_ error: Error?) { cancels += 1 }
}
'''

PROVIDER_REGRESSION = r'''
extension PacketTunnelProvider { func flushEffects() { watchdogQueue.sync {} } }
let cancelled = PacketTunnelProvider()
var completionCount = 0, failedStarts = 0, stopCount = 0
cancelled.startTunnel(options: nil) { error in
  completionCount += 1
  if error != nil { failedStarts += 1 }
}
cancelled.flushEffects()
cancelled.stopTunnel(with: .userInitiated) { stopCount += 1 }
cancelled.flushEffects()
cancelled.settingsCallbacks[0](nil)
cancelled.flushEffects()
require(completionCount == 1 && failedStarts == 1 && stopCount == 1,
        "an old settings callback must not report startup success after stop")
require(cancelled.packetFlow.readers.isEmpty, "stopped provider must not restart its packet reader")
'''

PROVIDER_TESTS = r'''
extension PacketTunnelProvider {
  func tickHeartbeat(_ elapsed: TimeInterval) {
    watchdogQueue.sync { expireHeartbeatIfNeeded(now: lastHeartbeatUptime + elapsed) }
  }
  func watchdogArmed() -> Bool { watchdogQueue.sync { watchdogTimer != nil } }
}
let provider = PacketTunnelProvider()
var oldStarts = 0, newStarts = 0
provider.startTunnel(options: nil) { error in require(error != nil, "superseded startup cancelled"); oldStarts += 1 }
provider.flushEffects()
provider.startTunnel(options: nil) { error in require(error == nil, "current startup succeeds"); newStarts += 1 }
provider.flushEffects()
provider.settingsCallbacks[0](nil)
provider.flushEffects()
require(newStarts == 0, "old settings callback cannot finish newer startup")
provider.settingsCallbacks[1](nil)
provider.flushEffects()
require(oldStarts == 1 && newStarts == 1, "each startup settles exactly once")
require(provider.watchdogArmed(), "watchdog armed only for live provider")
let oldReader = provider.packetFlow.readers[0]
provider.stopTunnel(with: .userInitiated) {}
provider.flushEffects()
provider.startTunnel(options: nil) { require($0 == nil, "restart succeeds") }
provider.flushEffects()
provider.settingsCallbacks[2](nil)
provider.flushEffects()
var packet = Data(repeating: 0, count: 20)
packet[0] = 0x45
packet.replaceSubrange(12..<16, with: [10, 7, 1, 1])
packet.replaceSubrange(16..<20, with: [10, 7, 0, 1])
oldReader([packet], [NSNumber(value: AF_INET)])
provider.flushEffects()
require(provider.packetFlow.writes.isEmpty, "old-generation packet callback is ignored")
require(provider.packetFlow.readers.count == 2, "old callback must not spawn a second read loop")
provider.packetFlow.readers[1]([packet, Data([1, 2])], [NSNumber(value: AF_INET), NSNumber(value: AF_INET)])
provider.flushEffects()
require(provider.packetFlow.writes.count == 1 && provider.packetFlow.writes[0].count == 1, "malformed packet rejected")
let reflected = provider.packetFlow.writes[0][0]
require(Array(reflected[12..<16]) == [10, 7, 0, 1] && Array(reflected[16..<20]) == [10, 7, 1, 1], "IPv4 reflection unchanged")
provider.tickHeartbeat(4.999)
require(provider.cancels == 0, "no early watchdog expiration")
var alive = false
provider.handleAppMessage(Data("heartbeat".utf8)) { alive = $0 == Data("alive".utf8) }
provider.flushEffects()
require(alive, "live heartbeat acknowledged")
provider.tickHeartbeat(5.0)
require(provider.cancels == 1 && !provider.watchdogArmed(), "watchdog closes at five seconds using monotonic time")
var revived = false
provider.handleAppMessage(Data("heartbeat".utf8)) { revived = $0 != nil }
provider.flushEffects()
provider.tickHeartbeat(10)
require(!revived && provider.cancels == 1, "late heartbeat cannot revive stopped tunnel")
let errored = PacketTunnelProvider()
var settingsFailed = false
errored.startTunnel(options: nil) { settingsFailed = $0 != nil }
errored.flushEffects()
errored.settingsCallbacks[0](NSError(domain: "TestSettings", code: 1))
errored.flushEffects()
require(settingsFailed && !errored.watchdogArmed() && errored.packetFlow.readers.isEmpty, "settings failure never becomes ready")
print("PASS: provider stop/start regression, late settings, old packets, reflection, heartbeat lease and settings errors")
'''


def check_manager_transport(manager_source: str) -> str:
    source = manager_source.replace('import Network\n', '').replace('import NetworkExtension\n', '')
    source = replace_method(source, 'private func providerBundleIdentifier()',
                            'private func providerBundleIdentifier() -> String? { "test.neostation.localtunnel" }')
    source = replace_method(source, 'private static func signingCapabilityFailure()',
                            'private static func signingCapabilityFailure() -> NeoStationLocalTunnelError? { TestPlatform.signingFailure }')
    # Accelerate only deadlines; production timing constants are statically
    # checked separately. Every transition and timeout branch remains real.
    for name, old, new in [('connectionPollInterval', '0.25', '0.005'),
                           ('connectionTimeout', '12', '0.12'),
                           ('disconnectionTimeout', '6', '0.12'),
                           ('disconnectErrorTimeout', '0.75', '0.015'),
                           ('routeProbeTimeout', '1.25', '0.015'),
                           ('heartbeatInterval', '1.5', '0.01')]:
        expected = f'static let {name}: TimeInterval = {old}'
        if expected not in source:
            raise AssertionError(f'Unexpected production duration: {name}')
        source = source.replace(expected, f'static let {name}: TimeInterval = {new}')
    return run_swift(PLATFORM + source + MANAGER_TESTS, 'PASS: transport scenarios A-H')


def check_provider_transport(provider_source: str, *, regression_only: bool = False) -> str:
    source = provider_source.replace('import NetworkExtension\n', '').replace('import os.log\n', '')
    tests = PROVIDER_REGRESSION
    if regression_only:
        tests += '\nprint("PASS: provider stop/start regression")\n'
    else:
        tests += PROVIDER_TESTS
    return run_swift(PROVIDER_PLATFORM + source + tests, 'PASS: provider stop/start regression')


class LocalJitTransportBehaviorTests(unittest.TestCase):
    def test_real_manager_with_simulated_platform_effects(self):
        print(check_manager_transport(MANAGER.read_text()))

    def test_real_provider_with_simulated_platform_effects(self):
        print(check_provider_transport(PROVIDER.read_text()))


if __name__ == '__main__':
    unittest.main()
