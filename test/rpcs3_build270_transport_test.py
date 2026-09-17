#!/usr/bin/env python3
"""Real production code with simulated OS effects, not an iPhone JIT test."""
from pathlib import Path
import argparse
import os
import subprocess
import sys
import tempfile
import local_jit_transport_behavior_test as transport

ROOT = Path(__file__).resolve().parents[1]
PROVIDER = ROOT / 'native/local_jit_tunnel/PacketTunnelProvider.swift'
MANAGER = ROOT / 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
HELPER = ROOT / 'packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift'

BLOCKED_IPC = r'''
extension PacketTunnelProvider {
  func flushControlForTest() { watchdogQueue.sync {} }
  // PUMP_FLUSH
}
let provider = PacketTunnelProvider()
let packetWritten = DispatchSemaphore(value: 0)
provider.packetFlow.onWrite = { packetWritten.signal() }
provider.startTunnel(options: nil) { require($0 == nil, "start must succeed") }
provider.flushControlForTest()
provider.settingsCallbacks[0](nil)
provider.flushControlForTest()
provider.flushPumpForTest()
let reader = provider.packetFlow.readers[0]
let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
provider.handleAppMessage(Data("heartbeat".utf8)) { _ in
  entered.signal()
  _ = release.wait(timeout: .now() + 3)
}
require(entered.wait(timeout: .now() + 2) == .success, "fake IPC reply is held")
var packet = Data(repeating: 0, count: 20)
packet[0] = 0x45
packet.replaceSubrange(12..<16, with: [10, 7, 1, 1])
packet.replaceSubrange(16..<20, with: [10, 7, 0, 1])
reader([packet], [NSNumber(value: AF_INET)])
let progressed = packetWritten.wait(timeout: .now() + 0.4) == .success
release.signal()
provider.flushControlForTest()
provider.flushPumpForTest()
require(progressed == EXPECT_PROGRESS, "packet processing must have the expected independence")
provider.stopTunnel(with: .userInitiated) {}
provider.flushControlForTest()
provider.flushPumpForTest()
print("PASS: build270 blocked control callback; packet progress=\(progressed)")
'''

PUMP_TESTS = r'''
let packet = Data([0x45] + Array(repeating: UInt8(0), count: 19))
let family = NSNumber(value: AF_INET)
// Refused batch is retained, retried, then delivered before another read.
let finished = DispatchSemaphore(value: 0)
var reads = 0, writes = 0
private let pump = NeoStationPacketPump(read: { callback in
  reads += 1
  if reads == 1 { callback([packet], [family]) } else { finished.signal() }
}, write: { packets, protocols in
  writes += 1
  precondition(packets.count == 1 && protocols.count == 1)
  return writes == 3
}, failed: { _ in preconditionFailure("transient backpressure should recover") })
pump.start(generation: 1)
precondition(finished.wait(timeout: .now() + 3) == .success)
pump.queue.sync { precondition(reads == 2 && writes == 3) }
pump.stop(); pump.queue.sync {}
// Permanent refusal reports exactly one error, no infinite loop/read backlog.
let failed = DispatchSemaphore(value: 0)
var failedWrites = 0, failedReads = 0
private let failing = NeoStationPacketPump(read: { callback in
  failedReads += 1; callback([packet], [family])
}, write: { _, _ in failedWrites += 1; return false }, failed: { epoch in
  precondition(epoch == 2); failed.signal()
})
failing.start(generation: 2)
precondition(failed.wait(timeout: .now() + 3) == .success)
failing.queue.sync { precondition(failedWrites == 4 && failedReads == 1) }
// Stop invalidates already queued retry and old read callbacks.
let attempted = DispatchSemaphore(value: 0)
var stoppedWrites = 0
private let stopped = NeoStationPacketPump(read: { callback in callback([packet], [family]) },
  write: { _, _ in stoppedWrites += 1; attempted.signal(); return false },
  failed: { _ in preconditionFailure("stopped retry cannot fail the newer provider") })
stopped.start(generation: 9)
precondition(attempted.wait(timeout: .now() + 2) == .success)
let stoppedDone = DispatchSemaphore(value: 0)
stopped.stop { stoppedDone.signal() }
precondition(stoppedDone.wait(timeout: .now() + 2) == .success)
Thread.sleep(forTimeInterval: 0.15)
stopped.queue.sync { precondition(stoppedWrites == 1) }
print("PASS: build270 bounded backpressure recovery, permanent refusal, no backlog, stop cancels retry")
'''

MANAGER_TESTS = r'''
extension NeoStationLocalTunnelManager {
  func hasNativeLease() -> Bool { activeDebuggerToken != nil }
  func heartbeatRunning() -> Bool { heartbeatTimer != nil }
  func generationForTest() -> UInt64 { operationGeneration }
}
DispatchQueue.global().async {
  let manager = NeoStationLocalTunnelManager.makeForTest()
  let owned = profile(true, .connected)
  main { TestPlatform.managers = [owned]; TestPlatform.probes = [true] }
  let ready = ResultBox()
  manager.ensureRunning(completion: ready.record)
  wait("owned ready") { ready.success != nil }
  let leased = ResultBox()
  manager.beginDebuggerLease(completion: leased.record)
  wait("lease ready") { !leased.results.isEmpty }
  let token = main { leased.success?["token"] as? String }
  require(token != nil, "provider token acknowledgement required")
  let generation = main { manager.generationForTest() }
  main {
    require(manager.hasNativeLease(), "native lease retained")
    require(!manager.heartbeatRunning(), "no host IPC heartbeat during debugger stops")
    TestPlatform.probes = [] // A maintenance probe here would be a test failure.
  }
  let automatic = ResultBox(), manualOn = ResultBox()
  manager.ensureRunning(completion: automatic.record)
  manager.enableOwned(completion: manualOn.record)
  wait("automatic frozen route") { automatic.success != nil }
  wait("manual ON keeps active route") { manualOn.success != nil }
  main {
    require(manager.generationForTest() == generation, "route not replaced during lease")
    require(owned.connection.stops == 0 && owned.connection.starts == 0, "no restart during lease")
    require(!manager.heartbeatRunning(), "route queries cannot restart heartbeats")
  }
  let stale = ResultBox()
  manager.endDebuggerLease(token: "00000000-0000-4000-8000-000000000000", completion: stale.record)
  wait("stale release") { !stale.results.isEmpty }
  main { require(manager.hasNativeLease(), "stale token must not release active lease") }
  let ended = ResultBox()
  manager.endDebuggerLease(token: token!, completion: ended.record)
  wait("released") { !ended.results.isEmpty }
  main { require(!manager.hasNativeLease() && manager.heartbeatRunning(), "normal heartbeat restored after detach") }
  let second = ResultBox()
  manager.beginDebuggerLease(completion: second.record)
  wait("second lease") { second.success != nil }
  let off = ResultBox()
  manager.disable(completion: off.record)
  wait("manual OFF") { !off.results.isEmpty }
  main {
    require(!manager.hasNativeLease() && !manager.heartbeatRunning(), "manual OFF invalidates lease")
    require(owned.connection.status == .disconnected, "owned VPN stops")
    manager.stopTestHeartbeat()
  }
  print("PASS: build270 native lease ownership, route reuse without IPC, stale release, restoration, manual OFF")
  exit(0)
}
dispatchMain()
'''

REPORTER_PLATFORM = r'''
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
enum NWEndpoint {
  struct Host { init(_ value: String) {} }
  struct Port { init?(rawValue: UInt16) { if rawValue == 0 { return nil } } }
}
struct NWParameters { static let tcp = NWParameters() }
enum FakeError: Error { case stopped }
final class NWConnection {
  enum State { case ready, failed(FakeError), waiting(FakeError) }
  enum SendCompletion { case contentProcessed((Error?) -> Void) }
  var stateUpdateHandler: ((State) -> Void)?
  static var sent = 0
  static var completeAutomatically = false
  static var completions = [() -> Void]()
  init(host: NWEndpoint.Host, port: NWEndpoint.Port, using: NWParameters) {}
  func start(queue: DispatchQueue) { stateUpdateHandler?(.ready) }
  func send(content: Data?, completion: SendCompletion) {
    Self.sent += 1
    if case .contentProcessed(let callback) = completion {
      if Self.completeAutomatically {
        let pending = Self.completions
        Self.completions.removeAll()
        DispatchQueue.global().async { pending.forEach { $0() }; callback(nil) }
      } else {
        Self.completions.append { callback(nil) } // target stopped, delay completion.
      }
    }
  }
  func cancel() {}
}
'''
REPORTER_TESTS = r'''
private let reporter = try Rpcs3HelperReporter(port: 1234, token: "test-token")
let before = Date()
for index in 0..<100 { try reporter.send(event: "log", message: "JIT test milestone \(index)") }
precondition(Date().timeIntervalSince(before) < 8, "stopped target must not stall helper logs")
precondition(NWConnection.sent == 32, "telemetry buffer bounded while target cannot read")
NWConnection.completions.forEach { $0() }
try reporter.send(event: "log", message: "resumed")
precondition(NWConnection.sent == 33, "backpressure released after target resumes")
NWConnection.completeAutomatically = true
try reporter.send(event: "complete", message: "done", success: true)
let previous = Rpcs3HelperJournal().takePrevious()
precondition(previous.count == 64 && previous.last!.contains("complete: done"), "journal survives reporter replacement")
precondition(Rpcs3HelperJournal().takePrevious().isEmpty, "recovered journal consumed once")
private let secret = Rpcs3HelperJournal()
secret.append("pairingData=never-save")
secret.append("token=never-save")
precondition(Rpcs3HelperJournal().takePrevious().isEmpty, "auth payloads not persisted")
print("PASS: build270 nonblocking bounded helper telemetry, durable journal recovery, auth redaction")
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', type=Path)
    args = parser.parse_args()
    paths = [PROVIDER, MANAGER, HELPER]
    before = [p.read_bytes() for p in paths]
    subprocess.run([sys.executable, str(ROOT / 'build-utils/patch_rpcs3_build270_transport.py')], check=True)
    assert before == [p.read_bytes() for p in paths], 'Build270 must be idempotent'
    provider = PROVIDER.read_text()
    # Exercise both old/new behavior with the SAME blocked-IPC schedule.
    platform = transport.PROVIDER_PLATFORM.replace('  var writes = [[Data]]()',
        '  var writes = [[Data]]()\n  var onWrite: (() -> Void)?')
    platform = platform.replace('writes.append(packets); return true', 'writes.append(packets); onWrite?(); return true')
    for source, expected in [(provider, True)] + ([(args.baseline.read_text(), False)] if args.baseline else []):
        clean = source.replace('import NetworkExtension\n', '').replace('import os.log\n', '')
        flush = 'func flushPumpForTest() { packetPump.queue.sync {} }' if expected else 'func flushPumpForTest() {}'
        tests = BLOCKED_IPC.replace('// PUMP_FLUSH', flush).replace('EXPECT_PROGRESS', str(expected).lower())
        print(transport.run_swift(platform + clean + tests, 'PASS: build270'))
    pump = (ROOT / 'build-utils/rpcs3/build270_packet_pump.swift.inc').read_text()
    print(transport.run_swift('import Foundation\n#if canImport(Darwin)\nimport Darwin\n#else\nimport Glibc\n#endif\n' + pump + PUMP_TESTS, 'PASS: build270'))
    # Only the OS sendProviderMessage effect is mocked; actual lease methods run.
    old_platform = transport.PLATFORM
    start = old_platform.index('  func sendProviderMessage(')
    updated = transport.replace_method(old_platform, '  func sendProviderMessage(', '''  func sendProviderMessage(_ data: Data, responseHandler: ((Data?) -> Void)?) throws {
    if String(data: data, encoding: .utf8) == "heartbeat" {
      responseHandler?(Data("alive".utf8)); return
    }
    var reply = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    reply["ok"] = true
    responseHandler?(try JSONSerialization.data(withJSONObject: reply))
  }''')
    transport.PLATFORM = updated
    helpers = transport.MANAGER_TESTS.split('DispatchQueue.global().async {', 1)[0]
    print(transport.check_manager_transport(MANAGER.read_text(), scenarios=helpers + MANAGER_TESTS, marker='PASS: build270'))
    transport.PLATFORM = old_platform
    reporter = HELPER.read_text().split('private final class Rpcs3HelperReporter', 1)[1]
    reporter = 'private final class Rpcs3HelperReporter' + reporter
    with tempfile.TemporaryDirectory(prefix='rpcs3-journal-270-') as directory:
        # Replace only the OS sandbox path, not journal/telemetry logic.
        reporter = reporter.replace('FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?',
            f'Optional(URL(fileURLWithPath: "{directory}"))?')
        print(transport.run_swift(REPORTER_PLATFORM + reporter + REPORTER_TESTS, 'PASS: build270'))
    host = (ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
    assert 'RPCS3EarlyLoaderCapture earlyLoaderCapture;' in host and 'native_identity_270' in host
    assert 'RTLD_NOW | RTLD_LOCAL' in host
    assert 'maximumHostSilence: TimeInterval = 180' in provider
    assert 'maximumLifetime: TimeInterval = 1020' in provider
    if sys.platform == 'darwin':
        with tempfile.TemporaryDirectory(prefix='rpcs3-early-270-') as directory:
            exe = str(Path(directory) / 'early-loader-test')
            subprocess.run(['clang++', '-std=c++17', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                '-I', str(ROOT), str(ROOT / 'test/native/rpcs3_early_loader_test.mm'), '-o', exe], check=True)
            assert subprocess.run([exe, directory, 'crash'], check=False).returncode == 23
            subprocess.run([exe, directory, 'recover'], check=True)
    print('PASS: build270 early-loader identity/capture wiring; existing JIT permissions and bounded lease retained')


if __name__ == '__main__':
    main()
