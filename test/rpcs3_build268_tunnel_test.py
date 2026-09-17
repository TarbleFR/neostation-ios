#!/usr/bin/env python3
"""Execute production Swift lease code with fake clocks and NE transport.

These are deterministic regression tests, not on-device JIT execution tests.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

POLICY_TESTS = r'''
func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }
let first = "00000000-0000-4000-8000-000000000001"
let second = "00000000-0000-4000-8000-000000000002"
var policy = NeoStationDebuggerLeasePolicy()
func expired(_ policy: NeoStationDebuggerLeasePolicy, last: TimeInterval, now: TimeInterval) -> Bool {
  now - last >= policy.timeout(normal: 5, now: now)
}
expect(expired(policy, last: 0, now: 5), "normal watchdog expires at five seconds")
expect(!policy.begin(token: "invalid", now: 0), "invalid lease refused")
expect(policy.begin(token: first, now: 0), "valid lease accepted")
for now in [6.0, 15, 30, 60, 179.9] {
  expect(!expired(policy, last: 0, now: now), "debugger stop must not close the route")
}
expect(expired(policy, last: 0, now: 180), "force-kill cleanup remains bounded")
expect(!policy.begin(token: second, now: 1), "overlapping lease refused")
expect(!policy.end(token: second), "stale release cannot close the first lease")
expect(!expired(policy, last: 10, now: 100), "stale release preserves protection")
expect(policy.begin(token: first, now: 1000), "same-token retry is idempotent")
expect(policy.timeout(normal: 5, now: 1020) == 5, "retry cannot extend the hard deadline")
expect(policy.end(token: first), "matching release accepted")
expect(policy.timeout(normal: 5, now: 1) == 5, "normal watchdog restored")
expect(policy.begin(token: second, now: 1030), "new lease may start")
expect(!policy.end(token: first), "late callback cannot release newer lease")
policy.reset()
expect(policy.token == nil, "manual stop clears protection")
expect(policy.timeout(normal: 5, now: 1031) == 5, "manual stop always wins")
print("PASS: 268 debugger suspension, bounded expiry, matching release, stale token, hard deadline, manual stop")
'''

TRANSPORT_STUBS = r'''
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
enum NeoStationLocalTunnelError: Error { case cancelled, start(String) }
enum NEVPNStatus { case connected, disconnected }
class NEVPNConnection { var status = NEVPNStatus.connected }
final class NETunnelProviderSession: NEVPNConnection {
  var mode = "echo"
  var sent = [[String: String]]()
  var held = [() -> Void]()
  func sendProviderMessage(_ data: Data, responseHandler: ((Data?) -> Void)?) throws {
    let request = try JSONSerialization.jsonObject(with: data) as! [String: String]
    sent.append(request)
    if mode == "throw" { throw NeoStationLocalTunnelError.start("test transport error") }
    guard let responseHandler else { return }
    var reply: [String: Any] = ["ok": true, "command": request["command"]!, "token": request["token"]!]
    if mode == "mismatch" { reply["token"] = "a-different-transaction" }
    let bytes = mode == "oldProvider" ? Data("ready".utf8) : try JSONSerialization.data(withJSONObject: reply)
    if mode == "hold" { held.append { responseHandler(bytes) } }
    else { responseHandler(bytes) }
  }
}
final class NETunnelProviderManager {
  let connection: NEVPNConnection = NETunnelProviderSession()
}
final class NeoStationLocalTunnelManager {
  typealias Response = Result<[String: Any], NeoStationLocalTunnelError>
  var stopRequested = false
  var disableInFlight = false
  var ensureInFlight = false
  var activeManager: NETunnelProviderManager?
  var operationGeneration: UInt64 = 0
}
final class Box {
  var result: NeoStationLocalTunnelManager.Response?
  var completions = 0
  func receive(_ result: NeoStationLocalTunnelManager.Response) { self.result = result; completions += 1 }
}
func main<T>(_ action: () -> T) -> T { DispatchQueue.main.sync(execute: action) }
func require(_ condition: Bool, _ message: String) { precondition(condition, message) }
func wait(_ box: Box) {
  let until = ProcessInfo.processInfo.systemUptime + 4.5
  while !main({ box.result != nil }) {
    require(ProcessInfo.processInfo.systemUptime < until, "callback must settle")
    Thread.sleep(forTimeInterval: 0.005)
  }
}
func succeeded(_ box: Box) -> [String: Any]? {
  if case .success(let result)? = box.result { return result }
  return nil
}
func failure(_ box: Box) -> Bool {
  if case .failure? = box.result { return true }
  return false
}
'''

TRANSPORT_TESTS = r'''
DispatchQueue.global().async {
  let external = NeoStationLocalTunnelManager()
  let untouched = Box()
  external.beginDebuggerLease(completion: untouched.receive)
  wait(untouched)
  main {
    require(succeeded(untouched)?["leased"] as? Bool == false, "external VPN is a no-op")
    require(succeeded(untouched)?["managedByNeoStation"] as? Bool == false, "external ownership retained")
  }
  let owned = NeoStationLocalTunnelManager()
  main { owned.activeManager = NETunnelProviderManager() }
  let accepted = Box()
  owned.beginDebuggerLease(completion: accepted.receive)
  wait(accepted)
  let token = main { succeeded(accepted)?["token"] as? String }
  require(token != nil, "owned lease requires matching provider acknowledgement")
  let released = Box()
  owned.endDebuggerLease(token: token!, completion: released.receive)
  wait(released)
  main {
    let session = owned.activeManager!.connection as! NETunnelProviderSession
    require(session.sent.map { $0["command"]! } == ["jitLeaseBegin", "jitLeaseEnd"], "begin/end wire order")
    require(session.sent.last?["token"] == token, "release carries its own token")
  }
  for mode in ["oldProvider", "mismatch", "throw"] {
    let manager = NeoStationLocalTunnelManager()
    main {
      manager.activeManager = NETunnelProviderManager()
      (manager.activeManager!.connection as! NETunnelProviderSession).mode = mode
    }
    let rejected = Box()
    manager.beginDebuggerLease(completion: rejected.receive)
    wait(rejected)
    main { require(failure(rejected), "an invalid acknowledgement cannot authorize JIT") }
  }
  let stopped = NeoStationLocalTunnelManager()
  main { stopped.stopRequested = true }
  let cancelled = Box()
  stopped.beginDebuggerLease(completion: cancelled.receive)
  wait(cancelled)
  main { require(failure(cancelled), "manual stop prevents a new lease") }

  // Exercise the actual native timeout and late-callback single completion.
  let delayed = NeoStationLocalTunnelManager()
  main {
    delayed.activeManager = NETunnelProviderManager()
    (delayed.activeManager!.connection as! NETunnelProviderSession).mode = "hold"
  }
  let expired = Box()
  delayed.beginDebuggerLease(completion: expired.receive)
  wait(expired)
  main {
    require(failure(expired), "missing acknowledgement is bounded and fails closed")
    let session = delayed.activeManager!.connection as! NETunnelProviderSession
    require(session.sent.last?["command"] == "jitLeaseEnd", "timeout cleans up only its token")
    session.held.forEach { $0() }
  }
  main {}
  main { require(expired.completions == 1, "late acknowledgement cannot complete twice") }

  let raced = NeoStationLocalTunnelManager()
  main {
    raced.activeManager = NETunnelProviderManager()
    (raced.activeManager!.connection as! NETunnelProviderSession).mode = "hold"
  }
  let raceResult = Box()
  raced.beginDebuggerLease(completion: raceResult.receive)
  main {}
  main {
    raced.operationGeneration += 1
    let session = raced.activeManager!.connection as! NETunnelProviderSession
    session.held.forEach { $0() }
  }
  wait(raceResult)
  main { require(failure(raceResult), "a newer stop/operation invalidates a stale acknowledgement") }
  print("PASS: 268 actual manager lease transport, external no-op, old provider, mismatch, errors, timeout, cancellation")
  exit(0)
}
dispatchMain()
'''


def run_swift(source, label):
    with tempfile.TemporaryDirectory(prefix='neostation-268-') as folder:
        path = Path(folder) / 'main.swift'
        path.write_text(source)
        result = subprocess.run(['swift', '-swift-version', '5', str(path)],
                                capture_output=True, text=True, timeout=45)
    if result.returncode or 'PASS: 268' not in result.stdout:
        raise AssertionError(f'{label}:\n{result.stdout}\n{result.stderr}')
    print(result.stdout.strip())


def main():
    paths = [ROOT / path for path in (
        'native/local_jit_tunnel/PacketTunnelProvider.swift',
        'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift',
        'packages/stikjit_bridge/ios/Classes/StikjitBridgePlugin.swift',
        'lib/services/local_jit_tunnel_service.dart',
        'lib/services/rpcs3_internal_service.dart',
    )]
    before = [path.read_bytes() for path in paths]
    subprocess.run(['python3', str(ROOT / 'build-utils/patch_rpcs3_build268_tunnel.py')], check=True)
    assert before == [path.read_bytes() for path in paths], 'Build 268 patch must be idempotent'
    provider, manager, plugin, lifecycle, runtime = [path.read_text() for path in paths]
    policy = provider.split('// NEOSTATION_DEBUGGER_LEASE_268:', 1)[1]
    policy = policy[policy.index('struct NeoStationDebuggerLeasePolicy'):]
    policy = policy.split('// END_NEOSTATION_DEBUGGER_LEASE_268', 1)[0]
    run_swift('import Foundation\n' + policy + POLICY_TESTS, 'provider policy')
    extension = manager[manager.index('// This code stays in the manager\'s file'):]
    run_swift(TRANSPORT_STUBS + extension + TRANSPORT_TESTS, 'manager transport')
    assert 'debuggerLease.timeout(normal: Configuration.heartbeatTimeout, now: now)' in provider
    assert 'debuggerLease.reset()' in provider
    assert 'self.debuggerLease.end(token: token)' in provider
    assert runtime.index('await LocalJitDebuggerLease.acquire();') < runtime.index('Rpcs3InternalBridge.prepareJit(')
    assert runtime.index('Rpcs3InternalBridge.completeJit()') < runtime.index('await LocalJitDebuggerLease.release();')
    assert 'finally {' in runtime[runtime.index('Rpcs3InternalBridge.completeJit()'):runtime.index('await LocalJitDebuggerLease.release();')]
    for method in ('refreshInBackground', 'stopForLifecycle'):
        body = lifecycle.split(f'static Future<void> {method}', 1)[1].split('++_lifecycleGeneration', 1)[0]
        assert 'LocalJitDebuggerLease.active' in body, method
    manual = lifecycle.split('static Future<LocalJitTunnelState> disable()', 1)[1].split('static Future', 1)[0]
    assert 'LocalJitDebuggerLease.active' not in manual, 'Manual OFF must remain immediate'
    assert 'beginDebuggerLease' in plugin and 'endDebuggerLease' in plugin
    print('PASS: 268 lease acquired before attach, held through detach, cleanup in finally, manual OFF retained')


if __name__ == '__main__':
    main()
