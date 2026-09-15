"""Execute the manager's real queue/cancellation methods without iOS services.

Only network/profile effects are replaced by manually completed test doubles.
This verifies asynchronous ordering; it is not an on-device VPN integration test.
"""
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

from local_jit_transport_behavior_test import (
    check_manager_transport,
    check_provider_transport,
)


def check_state_machine(manager_source: str) -> str:
    swift = shutil.which('swift')
    if not swift:
        raise AssertionError('Swift is required for local JIT state-machine tests')

    boundaries = (
        ('  func ensureRunning(completion:', '  func status(completion:'),
        ('  func disable(completion:', '  private func beginEnsureIfPossible()'),
        ('  private func beginEnsureIfPossible()', '  private func beginDisableIfPossible()'),
        ('  private func beginDisableIfPossible()', '  private func performEnsureJitRoute('),
        ('  private func ensureIsCurrent(', '  private func finishEnsure('),
        ('  private func finishEnsure(', '  private func finishDisable('),
        ('  private func finishDisable(', '  private func providerBundleIdentifier()'),
    )
    methods = []
    for start, end in boundaries:
        a = manager_source.index(start)
        b = manager_source.index(end, a)
        methods.append(manager_source[a:b])

    harness = r'''
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum NeoStationLocalTunnelError: Error { case cancelled }
final class TestConnection {
  var stops = 0
  func stopVPNTunnel() { stops += 1 }
}
final class NETunnelProviderManager {
  let connection = TestConnection()
}
final class QueueUnderTest {
  typealias Response = Result<[String: Any], NeoStationLocalTunnelError>
  private var ensureInFlight = false
  private var activeEnsureGeneration: UInt64?
  private var activeEnsureWaiters = [(Response) -> Void]()
  private var queuedEnsureWaiters = [(Response) -> Void]()
  private var disableInFlight = false
  private var disableWaiters = [(Response) -> Void]()
  private var operationGeneration: UInt64 = 0
  private var stopRequested = false
  private var activeManager: NETunnelProviderManager? = NETunnelProviderManager()

  var startedGenerations = [UInt64]()
  var disableOperations = 0
  var heartbeatStops = 0

  private func performEnsureJitRoute(generation: UInt64) {
    startedGenerations.append(generation)
  }
  private func performDisable() { disableOperations += 1 }
  private func stopHeartbeat() { heartbeatStops += 1 }
  func completeStart() {
    let current = activeEnsureGeneration.map(ensureIsCurrent) ?? false
    finishEnsure(current ? .success(["active": true]) : .failure(.cancelled))
  }
  func completeStop() { finishDisable(.success(["active": false])) }

/* ACTUAL_MANAGER_METHODS */
}

func require(_ value: Bool, _ message: String) {
  guard value else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}
func flushMain() { DispatchQueue.main.sync {} }

DispatchQueue.global().async {
  // Resume queued between two background transitions must be cancelled by
  // the second stop, even while an earlier start/profile save is unwinding.
  let manager = QueueUnderTest()
  var initialCancelled = false
  var queuedCancelled = false
  var stopsCompleted = 0
  manager.ensureRunning { response in
    if case .failure(.cancelled) = response { initialCancelled = true }
  }
  flushMain()
  manager.disable { _ in stopsCompleted += 1 }
  flushMain()
  manager.ensureRunning { response in
    if case .failure(.cancelled) = response { queuedCancelled = true }
  }
  flushMain()
  manager.disable { _ in stopsCompleted += 1 }
  flushMain()
  DispatchQueue.main.sync {
    require(manager.startedGenerations.count == 1, "stop does not start another route")
    manager.completeStart()
    require(initialCancelled, "in-flight start observes cancellation generation")
    require(manager.disableOperations == 1, "duplicate stops coalesce profile cleanup")
    manager.completeStop()
    require(manager.startedGenerations.count == 1,
            "a second stop cancels the older queued resume instead of restarting VPN")
    require(queuedCancelled, "cancelled queued caller receives a result")
    require(stopsCompleted == 2, "every stop caller completes")
  }

  // A genuinely newer foreground request is still allowed after shutdown.
  var newStartCompleted = false
  manager.ensureRunning { response in
    if case .success = response { newStartCompleted = true }
  }
  flushMain()
  DispatchQueue.main.sync {
    require(manager.startedGenerations.count == 2, "new foreground request may start")
    manager.completeStart()
    require(newStartCompleted, "new foreground caller receives success")
  }

  // Requests arriving after the final stop may wait for profile cleanup.
  let resumed = QueueUnderTest()
  resumed.disable { _ in }
  flushMain()
  var resumedCompleted = false
  resumed.ensureRunning { response in
    if case .success = response { resumedCompleted = true }
  }
  flushMain()
  DispatchQueue.main.sync {
    require(resumed.startedGenerations.isEmpty, "resume waits for stop persistence")
    resumed.completeStop()
    require(resumed.startedGenerations.count == 1, "newer resume survives cleanup")
    resumed.completeStart()
    require(resumedCompleted, "newer resume is delivered")
  }

  // Parallel game/lifecycle preflights share one activation and all complete.
  let coalesced = QueueUnderTest()
  var successes = 0
  for _ in 0..<3 {
    coalesced.ensureRunning { response in
      if case .success = response { successes += 1 }
    }
  }
  flushMain()
  DispatchQueue.main.sync {
    require(coalesced.startedGenerations.count == 1, "concurrent ensures coalesce")
    coalesced.completeStart()
    require(successes == 3, "every coalesced caller completes")
  }
  print("PASS: queued-stop cancellation, stale-start invalidation, stop coalescing, foreground restart, ensure coalescing")
  exit(0)
}
dispatchMain()
'''.replace('/* ACTUAL_MANAGER_METHODS */', '\n'.join(methods))

    with tempfile.TemporaryDirectory(prefix='neostation-jit-state-') as temp:
        script = Path(temp) / 'StateMachineTests.swift'
        script.write_text(harness, encoding='utf-8')
        result = subprocess.run(
            [swift, '-swift-version', '5', str(script)],
            capture_output=True,
            text=True,
            timeout=45,
            check=False,
        )
    if result.returncode:
        raise AssertionError(
            f'Swift JIT state-machine checks failed ({result.returncode}):\n'
            f'{result.stdout}\n{result.stderr}'
        )
    if 'PASS: queued-stop cancellation' not in result.stdout:
        raise AssertionError(f'Swift checks produced no success marker: {result.stdout}')
    # Keep every existing queue regression, then exercise the actual transport
    # and provider paths too. The existing CI contract entry point runs all three.
    provider = Path(__file__).resolve().parents[1] / 'native/local_jit_tunnel/PacketTunnelProvider.swift'
    return '\n'.join((
        result.stdout.strip(),
        check_manager_transport(manager_source),
        check_provider_transport(provider.read_text()),
    ))
