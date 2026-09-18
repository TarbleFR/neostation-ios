#!/usr/bin/env python3
"""Build 275: keep the user-enabled local VPN persistent.

Apply after Build 274. This patch does not change RPCS3, Dolphin, StikJIT
scripts, JIT attach order, or the Build 274 boot path. It only removes a
provider self-cancel on transient packet write failures and makes status/start
selection prefer the live owned NETunnelProviderManager over stale duplicates.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(name):
    return (ROOT / name).read_text()

def write(name, text):
    (ROOT / name).write_text(text)

def main():
    provider_name = 'native/local_jit_tunnel/PacketTunnelProvider.swift'
    provider = read(provider_name)

    old = '''      guard attempt < 3 else {
        running = false; ready = false; self.epoch &+= 1
        cancelTunnelWithError(failure("packet write failed after bounded retries", code: 4)); return
      }
'''
    new = '''      guard attempt < 3 else {
        // NEOSTATION_VPN_PERSISTENCE_275: a transient packetFlow write
        // failure must never tear down a user-enabled local VPN. Drop only
        // this reflected batch and continue reading the tunnel.
        droppedCount &+= UInt64(packets.count)
        readNext()
        return
      }
'''
    if 'NEOSTATION_VPN_PERSISTENCE_275' not in provider:
        if provider.count(old) != 1:
            raise RuntimeError('Build 275 provider failure anchor changed')
        provider = provider.replace(old, new, 1)
        write(provider_name, provider)

    manager_name = 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
    manager = read(manager_name)

    old_status = '''  func status(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      let generation = self.serial
      var done = false
      let end: (Response) -> Void = { result in
        guard !done else { return }; done = true
        NeoStationVPNDiagnostics.record("status", self.summary(result))
        completion(result)
      }
      NeoStationVPNDiagnostics.snapshotRPCS3()
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        DispatchQueue.main.async {
          guard !done else { return }
          if let error { end(.failure(Self.configurationFailure(error))); return }
          let owned = (managers ?? []).filter { Self.isOwned($0, providerBundleIdentifier: self.providerBundleIdentifier()) }
          let manager = owned.first(where: { Self.isActive($0.connection.status) }) ?? owned.first
          if self.serial == generation, self.current == nil { self.activeManager = manager }
          end(.success(self.response(for: manager)))
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        end(.failure(.timeout("build=271; stage=status.load-preferences; limit=4s")))
      }
    }
  }
'''
    new_status = '''  func status(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      // NEOSTATION_VPN_PERSISTENCE_275: the connection object is live. Do not
      // replace an active tunnel with a stale duplicate returned by preferences.
      if let cached = self.activeManager, Self.isActive(cached.connection.status) {
        NeoStationVPNDiagnostics.record(
          "status",
          "NEOSTATION_VPN_PERSISTENCE_275: using live cached manager; status=\(Self.statusName(cached.connection.status))"
        )
        completion(.success(self.response(for: cached)))
        return
      }

      let generation = self.serial
      let identifier = self.providerBundleIdentifier()
      var done = false
      let end: (Response) -> Void = { result in
        guard !done else { return }; done = true
        NeoStationVPNDiagnostics.record("status", self.summary(result))
        completion(result)
      }
      NeoStationVPNDiagnostics.snapshotRPCS3()
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        DispatchQueue.main.async {
          guard !done else { return }
          if let error { end(.failure(Self.configurationFailure(error))); return }
          let owned = (managers ?? []).filter {
            Self.isOwned($0, providerBundleIdentifier: identifier)
          }
          let manager =
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
            owned.first

          if self.serial == generation, self.current == nil {
            if let cached = self.activeManager,
               Self.isActive(cached.connection.status) {
              end(.success(self.response(for: cached)))
              return
            }
            self.activeManager = manager
          }
          end(.success(self.response(for: manager)))
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        end(.failure(.timeout("build=275; stage=status.load-preferences; limit=4s")))
      }
    }
  }
'''
    if 'using live cached manager' not in manager:
        if manager.count(old_status) != 1:
            raise RuntimeError('Build 275 status anchor changed')
        manager = manager.replace(old_status, new_status, 1)

    old_select = '''      let owned = managers.filter { Self.isOwned($0, providerBundleIdentifier: identifier) }
      let selected = owned.first(where: { Self.providerIdentifier(for: $0) == identifier }) ?? owned.first ?? NETunnelProviderManager()
'''
    new_select = '''      let owned = managers.filter { Self.isOwned($0, providerBundleIdentifier: identifier) }
      // Prefer the live/current profile. Old signed builds may have left an
      // owned duplicate behind; a disabled duplicate must not win selection.
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
'''
    if 'Old signed builds may have left an' not in manager:
        if manager.count(old_select) != 1:
            raise RuntimeError('Build 275 start selection anchor changed')
        manager = manager.replace(old_select, new_select, 1)

    write(manager_name, manager)
    print('Build 275: persistent local VPN; transient packet write failures no longer cancel the tunnel; live manager wins status/start selection.')

if __name__ == '__main__':
    main()
