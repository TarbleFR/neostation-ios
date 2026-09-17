#!/usr/bin/env python3
"""Build 268: protect the integrated route through RPCS3's two-phase JIT.

Core/JIT memory algorithms and the successful Dolphin account flow are retained.
Protection requires an acknowledged, token-scoped provider lease. The usual
five-second watchdog remains active outside debugger transactions.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace(path, old, new):
    text = path.read_text()
    if new in text:
        return
    if text.count(old) != 1:
        raise RuntimeError(f'{path.name}: expected exactly one anchor: {old[:80]}')
    path.write_text(text.replace(old, new, 1))


POLICY = r'''// NEOSTATION_DEBUGGER_LEASE_268: bounded protection, not a disabled watchdog.
struct NeoStationDebuggerLeasePolicy {
  static let maximumHostSilence: TimeInterval = 180
  static let maximumLifetime: TimeInterval = 1020
  private(set) var token: String?
  private var deadline: TimeInterval = 0

  mutating func begin(token candidate: String, now: TimeInterval) -> Bool {
    guard UUID(uuidString: candidate) != nil, now.isFinite else { return false }
    if let token, now < deadline {
      // A retry is idempotent and cannot extend the hard deadline.
      return token == candidate
    }
    token = candidate
    deadline = now + Self.maximumLifetime
    return true
  }

  mutating func end(token candidate: String) -> Bool {
    guard token == candidate else { return false }
    reset()
    return true
  }

  mutating func reset() {
    token = nil
    deadline = 0
  }

  func timeout(normal: TimeInterval, now: TimeInterval) -> TimeInterval {
    guard token != nil, now < deadline else { return normal }
    return Self.maximumHostSilence
  }
}
// END_NEOSTATION_DEBUGGER_LEASE_268
'''

MANAGER_EXTENSION = r'''
// This code stays in the manager's file to use its existing ownership and
// operation-generation checks, rather than discovering/controlling other VPNs.
@available(iOS 17.4, *)
extension NeoStationLocalTunnelManager {
  func beginDebuggerLease(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      guard !self.stopRequested, !self.disableInFlight, !self.ensureInFlight else {
        completion(.failure(.cancelled)); return
      }
      guard let manager = self.activeManager else {
        completion(.success(["leased": false, "managedByNeoStation": false]))
        return
      }
      guard manager.connection.status == .connected,
            let session = manager.connection as? NETunnelProviderSession else {
        completion(.failure(.start("The integrated JIT route is no longer connected.")))
        return
      }
      let token = UUID().uuidString
      self.exchangeDebuggerLease(
        command: "jitLeaseBegin", token: token, session: session,
        generation: self.operationGeneration
      ) { response in
        switch response {
        case .success:
          completion(.success([
            "leased": true, "managedByNeoStation": true, "token": token,
          ]))
        case .failure(let error):
          // A timed-out acknowledgement may have armed the provider.
          // Cancel only our token; never touch a newer transaction.
          if session.status == .connected,
             let data = try? JSONSerialization.data(withJSONObject: [
               "command": "jitLeaseEnd", "token": token,
             ]) {
            try? session.sendProviderMessage(data, responseHandler: nil)
          }
          completion(.failure(error))
        }
      }
    }
  }

  func endDebuggerLease(token: String, completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      guard let manager = self.activeManager,
            manager.connection.status == .connected,
            let session = manager.connection as? NETunnelProviderSession else {
        completion(.success(["released": false])); return
      }
      self.exchangeDebuggerLease(
        command: "jitLeaseEnd", token: token, session: session,
        generation: self.operationGeneration, completion: completion
      )
    }
  }

  private func exchangeDebuggerLease(
    command: String, token: String, session: NETunnelProviderSession,
    generation: UInt64, completion: @escaping (Response) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    var settled = false
    let finish: (Response) -> Void = { response in
      guard !settled else { return }
      settled = true
      guard self.operationGeneration == generation, !self.stopRequested,
            session.status == .connected else {
        completion(.failure(.cancelled)); return
      }
      completion(response)
    }
    do {
      let data = try JSONSerialization.data(withJSONObject: [
        "command": command, "token": token,
      ])
      try session.sendProviderMessage(data) { data in
        DispatchQueue.main.async {
          guard let data,
                let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                reply["ok"] as? Bool == true,
                reply["command"] as? String == command,
                reply["token"] as? String == token else {
            finish(.failure(.start("The tunnel did not acknowledge the RPCS3 debugger lease.")))
            return
          }
          finish(.success(reply))
        }
      }
    } catch {
      finish(.failure(.start("Could not protect the tunnel during RPCS3 JIT preparation.")))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      finish(.failure(.start("RPCS3 debugger lease acknowledgement timed out.")))
    }
  }
}
'''


def main():
    provider = ROOT / 'native/local_jit_tunnel/PacketTunnelProvider.swift'
    replace(provider, 'import os.log\n', 'import os.log\n\n' + POLICY)
    replace(provider, '  private var lastHeartbeatUptime: TimeInterval = 0',
            '  private var lastHeartbeatUptime: TimeInterval = 0\n  private var debuggerLease = NeoStationDebuggerLeasePolicy()')
    replace(provider, '    guard elapsed >= Configuration.heartbeatTimeout else { return }',
            '    guard elapsed >= debuggerLease.timeout(normal: Configuration.heartbeatTimeout, now: now) else { return }')
    replace(provider, '    watchdogTimer?.setEventHandler {}',
            '    debuggerLease.reset()\n    watchdogTimer?.setEventHandler {}')
    replace(provider, '''        completionHandler?(Data("alive".utf8))
      } else {
        completionHandler?(Data("ready".utf8))''', '''        completionHandler?(Data("alive".utf8))
      } else if messageData.count <= 512,
                let request = (try? JSONSerialization.jsonObject(with: messageData)) as? [String: Any],
                let command = request["command"] as? String,
                let token = request["token"] as? String,
                UUID(uuidString: token) != nil {
        let now = ProcessInfo.processInfo.systemUptime
        var accepted = false
        if command == "jitLeaseBegin" {
          accepted = self.debuggerLease.begin(token: token, now: now)
          if accepted {
            self.lastHeartbeatUptime = now
            self.logger.info("RPCS3 debugger lease armed; watchdog remains bounded.")
          }
        } else if command == "jitLeaseEnd" {
          // Stale releases cannot erase a newer lease or refresh its heartbeat.
          if self.debuggerLease.end(token: token) {
            self.lastHeartbeatUptime = now
            self.logger.info("RPCS3 debugger lease released; normal watchdog restored.")
          }
          accepted = true
        }
        completionHandler?(try? JSONSerialization.data(withJSONObject: [
          "ok": accepted, "command": command, "token": token,
        ]))
      } else {
        completionHandler?(Data("ready".utf8))''')

    classes = ROOT / 'packages/stikjit_bridge/ios/Classes'
    manager = classes / 'NeoStationLocalTunnelManager.swift'
    text = manager.read_text()
    if MANAGER_EXTENSION not in text:
        manager.write_text(text + MANAGER_EXTENSION)

    plugin = classes / 'StikjitBridgePlugin.swift'
    replace(plugin, '    if call.method == "ensureLocalTunnel" {', r'''    if call.method == "beginDebuggerLease" || call.method == "endDebuggerLease" {
      guard #available(iOS 17.4, *) else {
        result(FlutterError(code: "local_tunnel_unsupported_ios",
            message: "The integrated JIT tunnel requires iOS 17.4 or newer.", details: nil))
        return
      }
      let complete: (NeoStationLocalTunnelManager.Response) -> Void = { response in
        switch response {
        case .success(let state): result(state)
        case .failure(let error):
          result(FlutterError(code: "local_tunnel_\(error.code)",
              message: error.localizedDescription, details: nil))
        }
      }
      if call.method == "beginDebuggerLease" {
        NeoStationLocalTunnelManager.shared.beginDebuggerLease(completion: complete)
      } else if let args = call.arguments as? [String: Any],
                let token = args["token"] as? String, UUID(uuidString: token) != nil {
        NeoStationLocalTunnelManager.shared.endDebuggerLease(token: token, completion: complete)
      } else {
        result(FlutterError(code: "local_tunnel_invalid_lease", message: "Invalid debugger lease.", details: nil))
      }
      return
    }

    if call.method == "ensureLocalTunnel" {''')

    runtime = ROOT / 'lib/services/rpcs3_internal_service.dart'
    replace(runtime, "import 'local_jit_tunnel_service.dart';",
            "import 'local_jit_tunnel_service.dart';\nimport 'local_jit_debugger_lease.dart';")
    replace(runtime, '        await LocalJitTunnelService.ensureRunningForJit();',
            '        await LocalJitTunnelService.ensureRunningForJit();\n'
            '        // Must be acknowledged BEFORE StikJIT can suspend this process.\n'
            '        await LocalJitDebuggerLease.acquire();\n'
            "        _log.i('RPCS3 debugger tunnel protection confirmed.');")
    replace(runtime, '''    } catch (_) {
      _restartRequired = _jitCompletionPending;
      rethrow;
    }
  }

  /// A Universal attach''', '''    } catch (_) {
      _restartRequired = _jitCompletionPending;
      rethrow;
    } finally {
      // Keep the lease through dlopen, arena preparation AND helper detach.
      // Cleanup must never replace the actual initialization error.
      try {
        await LocalJitDebuggerLease.release();
      } catch (error) {
        _log.w('RPCS3 tunnel protection cleanup failed; provider expiry remains bounded: $error');
      }
    }
  }

  /// A Universal attach''')

    service = ROOT / 'lib/services/local_jit_tunnel_service.dart'
    replace(service, "import 'local_jit_session_coordinator.dart';",
            "import 'local_jit_session_coordinator.dart';\nimport 'local_jit_debugger_lease.dart';")
    for method in ('refreshInBackground', 'stopForLifecycle'):
        old = f'  static Future<void> {method}({{required String reason}}) async {{\n    if (!Platform.isIOS) return;'
        new = old + '''
    // A native helper transition may hide the frontend during JIT. Do not
    // restart or tear down its route mid-handshake. Manual disable is unchanged.
    if (LocalJitDebuggerLease.active) {
      _log.i('Local JIT lifecycle action deferred during RPCS3 debugger transaction.');
      return;
    }'''
        replace(service, old, new)
    print('Build 268 RPCS3 acknowledged tunnel lease applied; Dolphin and cores unchanged.')


if __name__ == '__main__':
    main()
