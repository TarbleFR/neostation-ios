#!/usr/bin/env python3
"""Build 276: definitive separation of VPN ownership from RemotePairing/JIT.

Apply after the device-tested Build 273 VPN policy. Manual ON/OFF owns only
NeoStation's NETunnelProvider profile. RemotePairing reachability is a separate
read-only JIT preflight and can never stop a connected/connecting/reasserting
VPN. RPCS3 itself is intentionally untouched; Build 276 uses the Build 273
RPCS3/JIT path.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(name):
    return (ROOT / name).read_text()

def write(name, text):
    (ROOT / name).write_text(text)

def replace_method(name, signature, replacement):
    text = read(name)
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
    write(name, text[:start] + replacement + text[end:])

def change(name, old, new):
    text = read(name)
    if old not in text and new in text:
        return
    if text.count(old) != 1:
        raise RuntimeError(f"{name}: unexpected anchor ({text.count(old)}): {old[:100]!r}")
    write(name, text.replace(old, new, 1))

def main():
    manager_name = 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'

    replace_method(
        manager_name,
        '  func enableOwned(completion: @escaping (Response) -> Void)',
        r'''  // NEOSTATION_VPN_FINAL_276: manual ON controls only the system tunnel.
  // RemotePairing/JIT reachability is deliberately NOT an activation condition.
  func enableOwned(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      if let previous = self.current, previous.intent == "activate-owned" {
        previous.waiters.append(completion)
        return
      }
      let request = self.begin("activate-owned", seconds: 60, completion: completion)
      if let manager = self.activeManager {
        switch manager.connection.status {
        case .connected:
          self.verify(manager, request)
          return
        case .connecting, .reasserting:
          if !request.touched.contains(where: { $0 === manager }) {
            request.touched.append(manager)
          }
          self.waitConnected(
            manager, request,
            deadline: ProcessInfo.processInfo.systemUptime + 30,
            observed: true
          )
          return
        default:
          break
        }
      }
      self.loadForStart(request)
    }
  }'''
    )

    replace_method(
        manager_name,
        '  private func fail(_ request: Request, _ error: NeoStationLocalTunnelError)',
        r'''  private func fail(_ request: Request, _ error: NeoStationLocalTunnelError) {
    guard valid(request) else { return }
    // A connected, connecting or reasserting tunnel is system-owned state.
    // Never turn it OFF because a provider diagnostic, timeout, RemotePairing
    // probe, RPCS3 operation or StikJIT operation failed.
    for manager in request.touched where !Self.isActive(manager.connection.status) {
      manager.connection.stopVPNTunnel()
    }
    finish(request, .failure(error))
  }'''
    )

    replace_method(
        manager_name,
        '  private func loadForStart(_ request: Request)',
        r'''  private func loadForStart(_ request: Request) {
    guard valid(request) else { return }
    guard let identifier = providerBundleIdentifier() else { fail(request, .extensionMissing); return }
    if let error = Self.signingCapabilityFailure() { fail(request, error); return }
    awaitValue(request, "start.load-preferences", start: { done in
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        if let error { done(.failure(error)) } else { done(.success(managers ?? [])) }
      }
    }) { (managers: [NETunnelProviderManager]) in
      let owned = managers.filter {
        Self.isOwned($0, providerBundleIdentifier: identifier)
      }
      let selected =
        owned.first(where: {
          Self.providerIdentifier(for: $0) == identifier &&
          Self.isActive($0.connection.status)
        }) ??
        owned.first(where: { Self.isActive($0.connection.status) }) ??
        owned.first(where: {
          Self.providerIdentifier(for: $0) == identifier && $0.isEnabled
        }) ??
        owned.first(where: { $0.isEnabled }) ??
        owned.first(where: { Self.providerIdentifier(for: $0) == identifier }) ??
        owned.first ??
        NETunnelProviderManager()

      self.activeManager = selected

      // Only stale NeoStation duplicates may be stopped. Never touch another
      // provider and never restart the selected tunnel while iOS is connecting.
      for manager in owned where manager !== selected &&
          Self.isActive(manager.connection.status) {
        manager.connection.stopVPNTunnel()
      }

      switch selected.connection.status {
      case .connected:
        self.verify(selected, request)
        return
      case .connecting, .reasserting:
        if !request.touched.contains(where: { $0 === selected }) {
          request.touched.append(selected)
        }
        self.waitConnected(
          selected, request,
          deadline: ProcessInfo.processInfo.systemUptime + 30,
          observed: true
        )
        return
      case .disconnecting:
        if !request.touched.contains(where: { $0 === selected }) {
          request.touched.append(selected)
        }
        self.waitStopped(
          [selected], request,
          deadline: ProcessInfo.processInfo.systemUptime + 8
        ) {
          self.persistAndStart(selected, identifier: identifier, request: request)
        }
        return
      case .disconnected, .invalid:
        if !request.touched.contains(where: { $0 === selected }) {
          request.touched.append(selected)
        }
        self.persistAndStart(selected, identifier: identifier, request: request)
        return
      @unknown default:
        self.fail(request, .start("Unknown NetworkExtension status before activation."))
      }
    }
  }

  private func persistAndStart(
    _ manager: NETunnelProviderManager,
    identifier: String,
    request: Request
  ) {
    guard valid(request) else { return }
    configure(manager, identifier)
    awaitValue(request, "start.save-preferences", seconds: 12, start: { done in
      manager.saveToPreferences { error in
        if let error { done(.failure(error)) } else { done(.success(())) }
      }
    }) { (_: Void) in
      self.awaitValue(request, "start.reload-preferences", start: { done in
        manager.loadFromPreferences { error in
          if let error { done(.failure(error)) } else { done(.success(())) }
        }
      }) { (_: Void) in
        self.start(manager, request)
      }
    }
  }'''
    )

    change(
        manager_name,
        'waitConnected(manager, request, deadline: ProcessInfo.processInfo.systemUptime + 12, observed: false)',
        'waitConnected(manager, request, deadline: ProcessInfo.processInfo.systemUptime + 30, observed: false)',
    )

    replace_method(
        manager_name,
        '  private func verify(_ manager: NETunnelProviderManager, _ request: Request)',
        r'''  private func verify(_ manager: NETunnelProviderManager, _ request: Request) {
    guard valid(request) else { return }
    guard manager.connection.status == .connected else {
      if Self.isActive(manager.connection.status) {
        self.waitConnected(
          manager, request,
          deadline: ProcessInfo.processInfo.systemUptime + 30,
          observed: true
        )
      } else {
        self.fail(
          request,
          .start("The NeoStation NetworkExtension did not remain active.")
        )
      }
      return
    }

    self.activeManager = manager
    NeoStationVPNDiagnostics.record(
      "vpn",
      "NEOSTATION_VPN_FINAL_276: system tunnel accepted independently of RemotePairing"
    )

    // The system tunnel is now ON. Provider/JIT/RemotePairing diagnostics are
    // observational only and must never decide whether the VPN remains ON.
    self.finish(
      request,
      .success(self.response(for: manager, routeVerified: false))
    )

    if let session = manager.connection as? NETunnelProviderSession {
      do {
        try session.sendProviderMessage(Data("vpn271-status".utf8)) { data in
          let alive = data != nil
          NeoStationVPNDiagnostics.record(
            "provider",
            "Build 276 post-connect diagnostic response=\(alive)"
          )
        }
      } catch {
        NeoStationVPNDiagnostics.record(
          "provider",
          "Build 276 post-connect diagnostic unavailable: \(Self.errorDetail(error))"
        )
      }
    }
  }'''
    )

    name = manager_name
    text = read(name)
    old = '"active": status == .connected, "status": Self.statusName(status),'
    new = '"active": Self.isActive(status), "status": Self.statusName(status),'
    if old in text:
        text = text.replace(old, new, 1)
    elif new not in text:
        raise RuntimeError('Build 276 response active-state anchor changed')
    write(name, text)

    # Packet provider: match LocalDevVPN's current point-to-point /32 geometry,
    # never self-cancel for transient write backpressure, and do not invent a
    # 10-second system-network-settings deadline that LocalDevVPN itself lacks.
    provider_name = 'native/local_jit_tunnel/PacketTunnelProvider.swift'
    provider = read(provider_name)
    provider = provider.replace(
        'NEIPv4Settings(addresses: ["10.7.1.1"], subnetMasks: ["255.255.255.0"])',
        'NEIPv4Settings(addresses: ["10.7.1.1"], subnetMasks: ["255.255.255.255"])',
    )
    provider = provider.replace(
        'settings.ipv4Settings = ipv4; settings.mtu = 1500',
        'settings.ipv4Settings = ipv4',
    )
    startup_timeout = r'''      self.queue.asyncAfter(deadline: .now() + 10) {
        guard self.epoch == epoch, self.pendingStart != nil else { return }
        self.running = false; self.ready = false; self.epoch &+= 1
        self.finishStart(self.failure("network settings callback missing after 10s", code: 3))
      }
'''
    provider = provider.replace(startup_timeout, '')
    old_write_failure = r'''      guard attempt < 3 else {
        running = false; ready = false; self.epoch &+= 1
        cancelTunnelWithError(failure("packet write failed after bounded retries", code: 4)); return
      }
'''
    new_write_failure = r'''      guard attempt < 3 else {
        // NEOSTATION_VPN_FINAL_276: packet backpressure may drop this reflected
        // batch, but it is never a reason to tear down the user's VPN.
        droppedCount &+= UInt64(packets.count)
        readNext()
        return
      }
'''
    if old_write_failure in provider:
        provider = provider.replace(old_write_failure, new_write_failure, 1)
    elif 'NEOSTATION_VPN_FINAL_276: packet backpressure' not in provider:
        raise RuntimeError('Build 276 provider write-failure anchor changed')
    write(provider_name, provider)

    # Manual Settings ON proves only that our system tunnel was accepted.
    # JIT route proof remains StikjitBridge.ensureJitRoute() and is read-only.
    dart_name = 'packages/stikjit_bridge/lib/stikjit_bridge.dart'
    dart = read(dart_name)
    old = 'if (!state.active || !state.routeVerified || !state.managedByNeoStation) {'
    new = 'if (!state.active || !state.managedByNeoStation) {'
    if old in dart:
        dart = dart.replace(old, new, 1)
    elif new not in dart:
        raise RuntimeError('Build 276 Dart activation guard changed')
    dart = dart.replace(
        'The integrated provider did not confirm the local JIT route.',
        'The integrated provider did not enter an active NetworkExtension state.',
    )
    write(dart_name, dart)

    # RPCS3 is intentionally not modified here.
    print(
        'Build 276: VPN lifecycle is independent of RemotePairing/RPCS3; '
        'provider uses /32 point-to-point geometry and has no self-cancel path.'
    )

if __name__ == '__main__':
    main()
