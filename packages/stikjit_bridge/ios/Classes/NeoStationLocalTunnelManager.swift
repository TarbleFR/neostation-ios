import Foundation
import NetworkExtension

/// Owns the system VPN configuration for NeoStation's device-local JIT route.
/// Calls are coalesced so startup, resume and game launch cannot create duplicate
/// NETunnelProviderManager records.
@available(iOS 17.4, *)
final class NeoStationLocalTunnelManager {
  static let shared = NeoStationLocalTunnelManager()

  private enum Constants {
    static let schemaVersion = 1
    static let schemaVersionKey = "schemaVersion"
    static let interfaceAddressKey = "interfaceAddress"
    static let peerAddressKey = "peerAddress"
    static let interfaceAddress = "10.7.1.1"
    static let peerAddress = "10.7.0.1"
    static let extensionName = "NeoStationLocalTunnel.appex"
    static let fallbackSuffix = ".localtunnel"
    static let localizedDescription = "NeoStation Local JIT Tunnel"
    static let serverAddress = "On-device RemotePairing route"
    static let connectionPollInterval: TimeInterval = 0.25
    static let connectionTimeout: TimeInterval = 45
  }

  typealias Response = Result<[String: Any], NeoStationLocalTunnelError>

  private var ensureInFlight = false
  private var ensureWaiters = [(Response) -> Void]()

  private init() {}

  func ensureRunning(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      self.ensureWaiters.append(completion)
      guard !self.ensureInFlight else { return }
      self.ensureInFlight = true
      self.performEnsureRunning()
    }
  }

  func status(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      guard let providerBundleIdentifier = self.providerBundleIdentifier() else {
        completion(.failure(.extensionMissing))
        return
      }
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        DispatchQueue.main.async {
          if let error {
            completion(.failure(.configuration(error.localizedDescription)))
            return
          }
          let manager = managers?.first(where: {
            Self.providerIdentifier(for: $0) == providerBundleIdentifier
          })
          completion(.success(self.response(for: manager?.connection.status ?? .invalid)))
        }
      }
    }
  }

  private func performEnsureRunning() {
    guard let providerBundleIdentifier = providerBundleIdentifier() else {
      finish(.failure(.extensionMissing))
      return
    }

    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      DispatchQueue.main.async {
        if let error {
          self.finish(.failure(.configuration(error.localizedDescription)))
          return
        }
        let loaded = managers ?? []
        if let conflicting = loaded.first(where: {
          !Self.isOwned($0, providerBundleIdentifier: providerBundleIdentifier) &&
            Self.isActive($0.connection.status)
        }) {
          let name = conflicting.localizedDescription ?? "another VPN"
          self.finish(.failure(.activeVPNConflict(name)))
          return
        }

        let matching = loaded.filter {
          Self.isOwned($0, providerBundleIdentifier: providerBundleIdentifier)
        }
        let manager = matching.first(where: {
          Self.providerIdentifier(for: $0) == providerBundleIdentifier
        }) ?? matching.first ?? NETunnelProviderManager()
        self.removeDuplicateManagers(
          matching.filter { $0 !== manager }
        ) { error in
          if let error {
            self.finish(.failure(.configuration(error.localizedDescription)))
            return
          }
          self.configure(
            manager,
            providerBundleIdentifier: providerBundleIdentifier
          )
          self.saveReloadAndStart(manager)
        }
      }
    }
  }

  private func removeDuplicateManagers(
    _ managers: [NETunnelProviderManager],
    completion: @escaping (Error?) -> Void
  ) {
    guard let manager = managers.first else {
      completion(nil)
      return
    }
    manager.removeFromPreferences { error in
      DispatchQueue.main.async {
        if let error {
          completion(error)
          return
        }
        self.removeDuplicateManagers(
          Array(managers.dropFirst()),
          completion: completion
        )
      }
    }
  }

  private func configure(
    _ manager: NETunnelProviderManager,
    providerBundleIdentifier: String
  ) {
    let tunnelProtocol =
      manager.protocolConfiguration as? NETunnelProviderProtocol ??
      NETunnelProviderProtocol()
    tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
    tunnelProtocol.serverAddress = Constants.serverAddress
    tunnelProtocol.providerConfiguration = [
      Constants.schemaVersionKey: Constants.schemaVersion,
      Constants.interfaceAddressKey: Constants.interfaceAddress,
      Constants.peerAddressKey: Constants.peerAddress,
    ]
    manager.protocolConfiguration = tunnelProtocol
    manager.localizedDescription = Constants.localizedDescription

    let onDemand = NEOnDemandRuleConnect()
    onDemand.interfaceTypeMatch = .any
    manager.onDemandRules = [onDemand]
    manager.isOnDemandEnabled = true
    manager.isEnabled = true
  }

  private func saveReloadAndStart(_ manager: NETunnelProviderManager) {
    manager.saveToPreferences { error in
      DispatchQueue.main.async {
        if let error {
          self.finish(.failure(.configuration(error.localizedDescription)))
          return
        }
        manager.loadFromPreferences { error in
          DispatchQueue.main.async {
            if let error {
              self.finish(.failure(.configuration(error.localizedDescription)))
              return
            }
            self.start(manager)
          }
        }
      }
    }
  }

  private func start(_ manager: NETunnelProviderManager) {
    if manager.connection.status == .connected {
      finish(.success(response(for: .connected)))
      return
    }
    if !Self.isActive(manager.connection.status) {
      do {
        try manager.connection.startVPNTunnel(options: [
          Constants.interfaceAddressKey: Constants.interfaceAddress as NSString,
          Constants.peerAddressKey: Constants.peerAddress as NSString,
        ])
      } catch {
        finish(.failure(.start(error.localizedDescription)))
        return
      }
    }
    waitUntilConnected(
      manager,
      deadline: Date().addingTimeInterval(Constants.connectionTimeout)
    )
  }

  private func waitUntilConnected(
    _ manager: NETunnelProviderManager,
    deadline: Date
  ) {
    switch manager.connection.status {
    case .connected:
      finish(.success(response(for: .connected)))
      return
    case .invalid:
      finish(.failure(.configuration("The saved VPN configuration is invalid.")))
      return
    default:
      break
    }

    guard Date() < deadline else {
      finish(.failure(.timeout))
      return
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Constants.connectionPollInterval
    ) {
      self.waitUntilConnected(manager, deadline: deadline)
    }
  }

  private func finish(_ response: Response) {
    dispatchPrecondition(condition: .onQueue(.main))
    let waiters = ensureWaiters
    ensureWaiters.removeAll(keepingCapacity: true)
    ensureInFlight = false
    for waiter in waiters {
      waiter(response)
    }
  }

  private func providerBundleIdentifier() -> String? {
    if let plugIns = Bundle.main.builtInPlugInsURL,
       let extensionBundle = Bundle(
         url: plugIns.appendingPathComponent(Constants.extensionName)
       ),
       let identifier = extensionBundle.bundleIdentifier,
       !identifier.isEmpty {
      return identifier
    }
    guard let host = Bundle.main.bundleIdentifier, !host.isEmpty else {
      return nil
    }
    return host + Constants.fallbackSuffix
  }

  private func response(for status: NEVPNStatus) -> [String: Any] {
    [
      "active": status == .connected,
      "status": Self.statusName(status),
      "managedByNeoStation": true,
      "interfaceAddress": Constants.interfaceAddress,
      "peerAddress": Constants.peerAddress,
      "onDemand": true,
    ]
  }

  private static func providerIdentifier(
    for manager: NETunnelProviderManager
  ) -> String? {
    (manager.protocolConfiguration as? NETunnelProviderProtocol)?
      .providerBundleIdentifier
  }

  private static func isOwned(
    _ manager: NETunnelProviderManager,
    providerBundleIdentifier: String
  ) -> Bool {
    if providerIdentifier(for: manager) == providerBundleIdentifier {
      return true
    }
    guard manager.localizedDescription == Constants.localizedDescription,
          let configuration =
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?
              .providerConfiguration,
          configuration[Constants.schemaVersionKey] as? Int ==
            Constants.schemaVersion else {
      return false
    }
    return true
  }

  private static func isActive(_ status: NEVPNStatus) -> Bool {
    status == .connected || status == .connecting || status == .reasserting
  }

  private static func statusName(_ status: NEVPNStatus) -> String {
    switch status {
    case .invalid: return "notConfigured"
    case .disconnected: return "disconnected"
    case .connecting: return "connecting"
    case .connected: return "connected"
    case .reasserting: return "reasserting"
    case .disconnecting: return "disconnecting"
    @unknown default: return "unknown"
    }
  }
}

@available(iOS 17.4, *)
enum NeoStationLocalTunnelError: LocalizedError {
  case extensionMissing
  case activeVPNConflict(String)
  case configuration(String)
  case start(String)
  case timeout

  var code: String {
    switch self {
    case .extensionMissing: return "extension_missing"
    case .activeVPNConflict: return "vpn_conflict"
    case .configuration: return "configuration_failed"
    case .start: return "start_failed"
    case .timeout: return "connection_timeout"
    }
  }

  var errorDescription: String? {
    switch self {
    case .extensionMissing:
      return "The NeoStation local tunnel extension is missing from this installation. Re-sign the complete IPA with app extensions enabled."
    case .activeVPNConflict(let name):
      return "NeoStation cannot start its local JIT tunnel while \(name) is active. Disconnect the other VPN and retry."
    case .configuration(let message):
      return "iOS could not save the NeoStation local tunnel. Confirm the VPN permission and preserve the Network Extension entitlement when signing. Technical detail: \(message)"
    case .start(let message):
      return "The NeoStation local JIT tunnel could not start: \(message)"
    case .timeout:
      return "The NeoStation local JIT tunnel did not become ready before the timeout."
    }
  }
}
