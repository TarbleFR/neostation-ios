#!/usr/bin/env python3
"""Build 270: independent packet transport during debugger stops and early logs.

Apply after Build 269. This does not change the emulation core, JIT page
permissions, pairing protocol, credentials, profiles, games or game caches.
The supplied device log locates termination inside dlopen, not its OS cause.
"""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]


def change(name, old, new):
    p = ROOT / name
    s = p.read_text()
    if not new and old not in s:
        return
    if new and new in s and not (new in old and old in s):
        return
    if s.count(old) != 1:
        raise RuntimeError(f'{name}: expected one preimage ({s.count(old)}): {old[:80]}')
    p.write_text(s.replace(old, new, 1))


def main():
    provider = 'native/local_jit_tunnel/PacketTunnelProvider.swift'
    manager = 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
    host = 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm'
    helper = 'packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift'
    jit = 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm'
    pump = (ROOT / 'build-utils/rpcs3/build270_packet_pump.swift.inc').read_text()
    change(provider, 'import os.log\n', 'import os.log\n\n' + pump)
    # Keep all lifecycle state and lease semantics on their existing queue.
    # Only the data plane gets an independent serial queue and per-item pools.
    change(provider, '  private var receivedHostHeartbeat = false', '''  private var receivedHostHeartbeat = false
  private lazy var packetPump = NeoStationPacketPump(
    read: { [weak self] callback in self?.packetFlow.readPackets(completionHandler: callback) },
    write: { [weak self] packets, protocols in
      self?.packetFlow.writePackets(packets, withProtocols: protocols) ?? false
    },
    failed: { [weak self] epoch in
      guard let self else { return }
      self.watchdogQueue.async {
        guard !self.stopped, self.generation == epoch else { return }
        self.stopped = true
        self.generation &+= 1
        self.stopWatchdog()
        self.cancelTunnelWithError(NSError(domain: "NeoStationLocalTunnel", code: 270,
          userInfo: [NSLocalizedDescriptionKey: "Build 270 packet transport could not write after bounded retries."]))
      }
    }
  )''')
    text = (ROOT / provider).read_text()
    start = text.index('  private func readAndReflectPackets() {')
    # This is the final method of the provider; strict trailer check.
    old = text[start:]
    new = '''  private func readAndReflectPackets() {
    dispatchPrecondition(condition: .onQueue(watchdogQueue))
    guard !stopped else { return }
    packetPump.start(generation: generation)
  }
}
'''
    if old != new:
        if 'self.packetFlow.writePackets(reflected' not in old or not old.endswith('\n}\n'):
            raise RuntimeError('Unexpected provider packet loop')
        (ROOT / provider).write_text(text[:start] + new)
    change(provider, '    debuggerLease.reset()\n    watchdogTimer?.setEventHandler {}',
           '    packetPump.stop()\n    debuggerLease.reset()\n    watchdogTimer?.setEventHandler {}')
    change(provider, '''      self.logger.info("Device-local JIT tunnel stopped with reason \\(reason.rawValue).")
      completionHandler()''', '''      self.logger.info("Device-local JIT tunnel stopped with reason \\(reason.rawValue).")
      self.packetPump.stop(completion: completionHandler)''')

    change(manager, '  private var heartbeatTimer: DispatchSourceTimer?', '''  private var heartbeatTimer: DispatchSourceTimer?
  // NEOSTATION_NATIVE_ROUTE_LEASE_270: freeze route maintenance, not manual OFF.
  private var activeDebuggerToken: String?''')
    change(manager, '''  private func requestRoute(owned: Bool, completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {''', '''  private func requestRoute(owned: Bool, completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      if self.reuseDebuggerRouteIfActive(completion: completion) { return }''')
    change(manager, '  func status(completion: @escaping (Response) -> Void) {', '''  private func reuseDebuggerRouteIfActive(completion: (Response) -> Void) -> Bool {
    guard activeDebuggerToken != nil else { return false }
    // This exact provider was verified before lease acquisition. A fresh IPC
    // probe while its containing process is debugger-stopped is not safe.
    guard !stopRequested, !disableInFlight, let manager = activeManager,
          manager.connection.status == .connected else {
      completion(.failure(.cancelled)); return true
    }
    completion(.success(response(for: manager, routeVerified: true)))
    return true
  }

  func status(completion: @escaping (Response) -> Void) {''')
    change(manager, '''  func disable(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {''', '''  func disable(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      self.activeDebuggerToken = nil''')
    change(manager, '  private func startHeartbeat(for manager: NETunnelProviderManager) {', '''  private func startHeartbeat(for manager: NETunnelProviderManager) {
    guard activeDebuggerToken == nil else { return }''')
    change(manager, '''      guard !self.stopRequested, !self.disableInFlight, !self.ensureInFlight else {''', '''      guard !self.stopRequested, !self.disableInFlight, !self.ensureInFlight,
            self.activeDebuggerToken == nil else {''')
    change(manager, '''        case .success:
          completion(.success([
            "leased": true''', '''        case .success:
          self.activeDebuggerToken = token
          self.trace.append("nativeDebuggerLease270=active")
          // Do not send host-owned NetworkExtension IPC while the debugger
          // suspends that host. The provider's bounded lease remains in force.
          self.stopHeartbeat()
          completion(.success([
            "leased": true''')
    change(manager, '''    DispatchQueue.main.async {
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

  private func exchangeDebuggerLease''', '''    DispatchQueue.main.async {
      guard self.activeDebuggerToken == token else {
        completion(.success(["released": false])); return
      }
      let restore: (Response) -> Void = { response in
        if self.activeDebuggerToken == token {
          self.activeDebuggerToken = nil
          if !self.stopRequested, let manager = self.activeManager,
             manager.connection.status == .connected {
            self.startHeartbeat(for: manager)
          }
        }
        completion(response)
      }
      guard let manager = self.activeManager,
            manager.connection.status == .connected,
            let session = manager.connection as? NETunnelProviderSession else {
        restore(.success(["released": false])); return
      }
      self.exchangeDebuggerLease(
        command: "jitLeaseEnd", token: token, session: session,
        generation: self.operationGeneration, completion: restore
      )
    }
  }

  private func exchangeDebuggerLease''')
    # Share one ODR-coalesced inline diagnostic writer between native TUs.
    # The old static-inline writer had separate file handles/locks per TU.
    change('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h',
           'static inline void RPCS3Diagnostic(', 'inline void RPCS3Diagnostic(')
    change(host, '#import "Rpcs3Diagnostics.h"',
           '#import "Rpcs3Diagnostics.h"\n#import "Rpcs3EarlyLoaderDiagnostics.h"')
    change(host, '      RPCS3Diagnostic(@"core_load_begin", expanded ? @"expanded arena" : @"standard arena");', '\n'.join([
        '      RPCS3Diagnostic(@"native_identity_270", [NSString stringWithFormat:',
        '          @"native=NEOSTATION_RPCSS3_TRANSPORT_270 appBuild=%@ bundle=%@ pid=%d",',
        '          [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",',
        '          NSBundle.mainBundle.bundleIdentifier ?: @"unknown", getpid()]);',
        '      RPCS3Diagnostic(@"core_load_begin", expanded ? @"expanded arena" : @"standard arena");',
    ]))
    change(host, '      handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);', '''      {
        RPCS3EarlyLoaderCapture earlyLoaderCapture;
        handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
          const char* earlyError = dlerror();
          if (earlyError) lastLoadError = [NSString stringWithUTF8String:earlyError] ?: @"unknown";
        }
      }''')
    change(host, '\n        const char* loadError = dlerror();\n        if (loadError) lastLoadError = [NSString stringWithUTF8String:loadError] ?: @"unknown";', '')
    change(host, '+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {', '''+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  RPCS3RecoverEarlyLoaderLog();
  RPCS3Diagnostic(@"host_identity_270", [NSString stringWithFormat:
      @"native=NEOSTATION_RPCSS3_TRANSPORT_270 appBuild=%@ bundle=%@ pid=%d",
      [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
      NSBundle.mainBundle.bundleIdentifier ?: @"unknown", getpid()]);''')
    change(jit, '#import "Rpcs3JitBridgePlugin.h"',
           '#import "Rpcs3JitBridgePlugin.h"\n#import "Rpcs3Diagnostics.h"')
    change(jit, '''        [strongSelf->_condition lock];
        if ([event isEqualToString:@"helper_connected"]) {''', '''        // Persist helper milestones instead of keeping them solely in memory.
        // Never serialize the mailbox token or pairing request into a log.
        if (message.length > 0) {
          NSString* bounded = message.length > 4096 ? [message substringToIndex:4096] : message;
          RPCS3Diagnostic([@"jit_helper_" stringByAppendingString:event], bounded);
        }
        [strongSelf->_condition lock];
        if ([event isEqualToString:@"helper_connected"]) {''')
    change(jit, '''          if (message.length > 0) [strongSelf->_mutableLogs addObject:message];''', '''          if (message.length > 0) {
            [strongSelf->_mutableLogs addObject:message];
            if (strongSelf->_mutableLogs.count > 64) [strongSelf->_mutableLogs removeObjectAtIndex:0];
          }''')

    change(helper, "    sendLock.lock()\n    defer { sendLock.unlock() }\n\n    var payload:", "    var payload:")
    change(helper, '      "message": message,', '      "message": String(message.prefix(4096)),')
    # Non-blocking telemetry. Critical control events still use the existing
    # acknowledged socket path, before attach / after detach, never per page.
    change(helper, '''  private var started = false''', '''  private var started = false
  private var pendingLogs = 0
  private let journal = Rpcs3HelperJournal()''')
    change(helper, '''      try reporter?.send(
        event: "log",
        message: "Preparing StikJIT 1.5.0 universal.js''', '''      reporter?.recoverPreviousDiagnostics()
      try reporter?.send(
        event: "log",
        message: "Preparing StikJIT 1.5.0 universal.js''')
    change(helper, '''    data.append(0x0A)
    let semaphore = DispatchSemaphore(value: 0)''', '''    data.append(0x0A)
    sendLock.lock()
    if event == "log" {
      // A stopped target must never hold the JIT script waiting for telemetry.
      // Bound pending network messages even if the target stops reading.
      journal.append(message)
      guard pendingLogs < 32 else { sendLock.unlock(); return }
      pendingLogs += 1
      connection.send(content: data, completion: .contentProcessed { [weak self] _ in
        guard let self else { return }
        self.sendLock.lock()
        self.pendingLogs -= 1
        self.sendLock.unlock()
      })
      sendLock.unlock()
      return
    }
    if event == "complete" { journal.append("complete: " + message) }
    let semaphore = DispatchSemaphore(value: 0)''')
    change(helper, "    guard semaphore.wait(timeout: .now() + 20) == .success else {\n      throw Rpcs3HelperError.connection(\n        \"Timed out writing to NeoStation.\"", "    sendLock.unlock() // Never wait while holding the telemetry callback lock.\n    guard semaphore.wait(timeout: .now() + 20) == .success else {\n      throw Rpcs3HelperError.connection(\n        \"Timed out writing to NeoStation.\"")
    change(helper, '''  func close() {
    if started''', '''  func recoverPreviousDiagnostics() {
    // The helper has its own sandbox. Recover its last bounded journal through
    // our authenticated loopback channel, without requesting App Groups.
    for message in journal.takePrevious() {
      try? send(event: "previous_helper_log", message: message)
    }
  }

  func close() {
    if started''')
    journal = '''
// NEOSTATION_HELPER_JOURNAL_270: retained even if the host dies while stopped.
private final class Rpcs3HelperJournal {
  private let path: URL?
  private var entries = [String]()
  init() {
    path = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
      .appendingPathComponent("RPCS3-JIT-last.json")
  }
  func takePrevious() -> [String] {
    guard let path else { return [] }
    defer { try? FileManager.defaultManager.removeItem(at: path) }
    guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          size <= 262144, let data = try? Data(contentsOf: path),
          let previous = (try? JSONSerialization.jsonObject(with: data)) as? [String] else { return [] }
    return Array(previous.suffix(64)).map { String($0.prefix(2048)) }
  }
  func append(_ message: String) {
    let lower = message.lowercased()
    // Debugger addresses are useful; pairing contents and auth tokens are not.
    guard !lower.contains("pairingdata"), !lower.contains("token"),
          !lower.contains("pairing record"), !lower.contains("script text:") else { return }
    entries.append("\\(Date().timeIntervalSince1970) " + String(message.prefix(2048)))
    if entries.count > 64 { entries.removeFirst(entries.count - 64) }
    guard let path else { return }
    while let data = try? JSONSerialization.data(withJSONObject: entries) {
      if data.count <= 131072 {
        try? data.write(to: path, options: [.atomic])
        return
      }
      guard entries.count > 1 else { return }
      entries.removeFirst()
    }
  }
}
'''
    change(helper, '\nprivate enum Rpcs3HelperError:', journal + '\nprivate enum Rpcs3HelperError:')
    # Keep legacy regression cases operating on the actual new implementation.
    # Do not reapply the superseded 269 transform after its output was upgraded.
    test = 'test/local_tunnel_build269_test.py'
    change(test, "    subprocess.run(['python3', str(ROOT / 'build-utils/patch_local_tunnel_build269.py')], check=True)",
           "    if 'NEOSTATION_RPCSS3_PACKET_PUMP_270' not in P.read_text():\n        subprocess.run(['python3', str(ROOT / 'build-utils/patch_local_tunnel_build269.py')], check=True)")
    change('test/local_jit_transport_behavior_test.py',
           '  func writePackets(_ packets: [Data], withProtocols: [NSNumber]) { writes.append(packets) }',
           '  func writePackets(_ packets: [Data], withProtocols: [NSNumber]) -> Bool { writes.append(packets); return true }')
    change('test/local_jit_transport_behavior_test.py',
           'extension PacketTunnelProvider { func flushEffects() { watchdogQueue.sync {} } }',
           'extension PacketTunnelProvider { func flushEffects() { watchdogQueue.sync {}; packetPump.queue.sync {}; watchdogQueue.sync {} } }')
    # Production manager methods are extracted into a queue-only harness whose
    # network effects are stubs. Full manager behavior is covered separately.
    change('test/local_jit_state_machine_check.py', '  private var stopRequested = false',
           '  private var stopRequested = false\n  private var activeDebuggerToken: String?')
    change('test/local_jit_state_machine_check.py', 'final class TestConnection {',
           'enum NEVPNStatus { case connected, disconnected }\nfinal class TestConnection {\n  var status = NEVPNStatus.connected')
    change('test/local_jit_state_machine_check.py', '  private func stopHeartbeat() { heartbeatStops += 1 }',
           '  private func stopHeartbeat() { heartbeatStops += 1 }\n  private func response(for manager: NETunnelProviderManager, routeVerified: Bool) -> [String: Any] { ["active": true] }')
    # Allowlisted host-only additions; this never permits a changed core source.
    reuse = 'build-utils/reuse_build266_rpcs3_for267.py'
    change(reuse, "ALLOWED = {", "ALLOWED = {\n    'build-utils/patch_rpcs3_build270_transport.py',\n    'build-utils/rpcs3/build270_packet_pump.swift.inc',\n    'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3EarlyLoaderDiagnostics.h',\n    'test/rpcs3_build270_transport_test.py',\n    'test/native/rpcs3_early_loader_test.mm',\n    'build-utils/validate_build270_identity.py',")
    change('test/rpcs3_savestate_ui_contract_test.py',
           "in ('267', '268', '269')", "in ('267', '268', '269', '270')")
    change('build-utils/validate_build269_identity.py', 'def verify(path):', 'def verify(path, build_number="269"):')
    change('build-utils/validate_build269_identity.py', "report = validate(path, '269')", 'report = validate(path, build_number)')
    print('Build 270 applied: independent packet pump, frozen native route, nonblocking helper telemetry, early-loader recovery.')


if __name__ == '__main__':
    main()
