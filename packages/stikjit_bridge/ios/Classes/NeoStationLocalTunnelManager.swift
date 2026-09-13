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
    static let localizedDescription = "NeoStation Local JIT Tunnel"
    static let serverAddress = "On-device RemotePairing route"
    static let connectionPollInterval: TimeInterval = 0.25
    static let connectionTimeout: TimeInterval = 45
    static let disconnectionTimeout: TimeInterval = 10
  }

  typealias Response = Result<[String: Any], NeoStationLocalTunnelError>

  private var ensureInFlight = false
  private var ensureWaiters = [(Response) -> Void]()
  private var disableInFlight = false
  private var disableWaiters = [(Response) -> Void]()

  private init() {}

  func ensureRunning(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      self.ensureWaiters.append(completion)
      self.beginEnsureIfPossible()
    }
  }

  func status(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      guard let providerBundleIdentifier = self.providerBundleIdentifier() else {
        completion(.failure(.extensionMissing))
        return
      }
      if let signingFailure = Self.signingCapabilityFailure() {
        completion(.failure(signingFailure))
        return
      }
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        DispatchQueue.main.async {
          if let error {
            completion(.failure(Self.configurationFailure(error)))
            return
          }
          let matching = managers?.filter {
            Self.isOwned(
              $0,
              providerBundleIdentifier: providerBundleIdentifier
            )
          } ?? []
          let manager = matching.first(where: {
            Self.isActive($0.connection.status)
          }) ?? matching.first(where: {
            Self.providerIdentifier(for: $0) == providerBundleIdentifier
          }) ?? matching.first
          completion(.success(self.response(for: manager)))
        }
      }
    }
  }

  /// Stops the connection and persists on-demand as disabled while retaining
  /// the system configuration. A later enable therefore reuses the permission
  /// already granted by iOS instead of creating a duplicate VPN profile.
  func disable(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      self.disableWaiters.append(completion)
      self.beginDisableIfPossible()
    }
  }

  private func beginEnsureIfPossible() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !ensureInFlight, !disableInFlight, !ensureWaiters.isEmpty else {
      return
    }
    ensureInFlight = true
    performEnsureRunning()
  }

  private func beginDisableIfPossible() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !disableInFlight, !ensureInFlight, !disableWaiters.isEmpty else {
      return
    }
    disableInFlight = true
    performDisable()
  }

  private func performEnsureRunning() {
    guard let providerBundleIdentifier = providerBundleIdentifier() else {
      finishEnsure(.failure(.extensionMissing))
      return
    }
    if let signingFailure = Self.signingCapabilityFailure() {
      finishEnsure(.failure(signingFailure))
      return
    }

    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      DispatchQueue.main.async {
        if let error {
          self.finishEnsure(.failure(Self.configurationFailure(error)))
          return
        }
        let loaded = managers ?? []
        if let conflicting = loaded.first(where: {
          !Self.isOwned($0, providerBundleIdentifier: providerBundleIdentifier) &&
            Self.isActive($0.connection.status)
        }) {
          let name = conflicting.localizedDescription ?? "another VPN"
          self.finishEnsure(.failure(.activeVPNConflict(name)))
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
            self.finishEnsure(.failure(Self.configurationFailure(error)))
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

  private func performDisable() {
    guard let providerBundleIdentifier = providerBundleIdentifier() else {
      finishDisable(.failure(.extensionMissing))
      return
    }
    if let signingFailure = Self.signingCapabilityFailure() {
      finishDisable(.failure(signingFailure))
      return
    }

    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      DispatchQueue.main.async {
        if let error {
          self.finishDisable(.failure(Self.configurationFailure(error)))
          return
        }
        let matching = managers?.filter {
          Self.isOwned(
            $0,
            providerBundleIdentifier: providerBundleIdentifier
          )
        } ?? []
        guard let manager = matching.first(where: {
          Self.isActive($0.connection.status)
        }) ?? matching.first(where: {
          Self.providerIdentifier(for: $0) == providerBundleIdentifier
        }) ?? matching.first else {
          self.finishDisable(.success(self.response(for: nil)))
          return
        }

        self.removeDuplicateManagers(
          matching.filter { $0 !== manager }
        ) { error in
          if let error {
            self.finishDisable(.failure(Self.configurationFailure(error)))
            return
          }
          // Repair signer rewrites or stale provider metadata before keeping
          // the accepted profile in its disabled state.
          self.configure(
            manager,
            providerBundleIdentifier: providerBundleIdentifier
          )
          manager.isOnDemandEnabled = false
          // The on-demand flag represents the user's persisted service choice;
          // isEnabled keeps the profile reusable without another authorization
          // transaction.
          manager.isEnabled = true
          self.saveReloadAndStop(manager)
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
          self.finishEnsure(.failure(Self.configurationFailure(error)))
          return
        }
        manager.loadFromPreferences { error in
          DispatchQueue.main.async {
            if let error {
              self.finishEnsure(.failure(Self.configurationFailure(error)))
              return
            }
            self.start(manager)
          }
        }
      }
    }
  }

  private func saveReloadAndStop(_ manager: NETunnelProviderManager) {
    manager.saveToPreferences { error in
      DispatchQueue.main.async {
        if let error {
          self.finishDisable(.failure(Self.configurationFailure(error)))
          return
        }
        manager.loadFromPreferences { error in
          DispatchQueue.main.async {
            if let error {
              self.finishDisable(.failure(Self.configurationFailure(error)))
              return
            }
            manager.connection.stopVPNTunnel()
            self.waitUntilDisconnected(
              manager,
              deadline: Date().addingTimeInterval(
                Constants.disconnectionTimeout
              )
            )
          }
        }
      }
    }
  }

  private func start(_ manager: NETunnelProviderManager) {
    if manager.connection.status == .connected {
      finishEnsure(.success(response(for: manager)))
      return
    }
    if !Self.isActive(manager.connection.status) {
      do {
        try manager.connection.startVPNTunnel(options: [
          Constants.interfaceAddressKey: Constants.interfaceAddress as NSString,
          Constants.peerAddressKey: Constants.peerAddress as NSString,
        ])
      } catch {
        finishEnsure(.failure(.start(error.localizedDescription)))
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
      finishEnsure(.success(response(for: manager)))
      return
    case .invalid:
      finishEnsure(
        .failure(.configuration("The saved VPN configuration is invalid."))
      )
      return
    default:
      break
    }

    guard Date() < deadline else {
      finishEnsure(.failure(.timeout))
      return
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Constants.connectionPollInterval
    ) {
      self.waitUntilConnected(manager, deadline: deadline)
    }
  }

  private func waitUntilDisconnected(
    _ manager: NETunnelProviderManager,
    deadline: Date
  ) {
    switch manager.connection.status {
    case .disconnected, .invalid:
      finishDisable(.success(response(for: manager)))
      return
    default:
      break
    }

    guard Date() < deadline else {
      finishDisable(.failure(.stop("The VPN connection did not stop.")))
      return
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Constants.connectionPollInterval
    ) {
      self.waitUntilDisconnected(manager, deadline: deadline)
    }
  }

  private func finishEnsure(_ response: Response) {
    dispatchPrecondition(condition: .onQueue(.main))
    let waiters = ensureWaiters
    ensureWaiters.removeAll(keepingCapacity: true)
    ensureInFlight = false
    beginDisableIfPossible()
    for waiter in waiters {
      waiter(response)
    }
  }

  private func finishDisable(_ response: Response) {
    dispatchPrecondition(condition: .onQueue(.main))
    let waiters = disableWaiters
    disableWaiters.removeAll(keepingCapacity: true)
    disableInFlight = false
    beginEnsureIfPossible()
    for waiter in waiters {
      waiter(response)
    }
  }

  private func providerBundleIdentifier() -> String? {
    if let extensionBundle = Self.installedExtensionBundle(),
       let identifier = extensionBundle.bundleIdentifier,
       !identifier.isEmpty {
      return identifier
    }
    // Never manufacture an identifier when a sideload signer removed the
    // nested extension. Doing so turns a packaging failure into the misleading
    // NEVPNError.configurationReadWriteFailed shown by iOS.
    return nil
  }

  /// NetworkExtension preferences can only be written when the installed host
  /// and extension profiles contain the Apple-authorized capabilities. The
  /// unsigned distribution IPA declares them, but a sideload signer may omit
  /// them while creating the final device provisioning profiles.
  private static func signingCapabilityFailure() -> NeoStationLocalTunnelError? {
    guard let extensionBundle = installedExtensionBundle() else {
      return .extensionMissing
    }
    if let host = provisioningEntitlements(in: Bundle.main),
       !entitlement(
         host,
         key: "com.apple.developer.networking.networkextension",
         contains: "packet-tunnel-provider"
       ) {
      return .signingMissing
    }
    if let tunnel = provisioningEntitlements(in: extensionBundle),
       !entitlement(
         tunnel,
         key: "com.apple.developer.networking.networkextension",
         contains: "packet-tunnel-provider"
       ) {
      return .signingMissing
    }
    return nil
  }

  private static func entitlement(
    _ entitlements: [String: Any],
    key: String,
    contains requiredValue: String
  ) -> Bool {
    let value = entitlements[key]
    if let values = value as? [String] {
      return values.contains(requiredValue)
    }
    return (value as? String) == requiredValue
  }

  /// A provisioning profile is a CMS envelope containing an XML property list.
  /// Reading the embedded property list avoids private entitlement-inspection
  /// APIs and reflects the profile produced by the user's final sideload signer.
  private static func provisioningEntitlements(
    in bundle: Bundle
  ) -> [String: Any]? {
    guard let url = bundle.url(
      forResource: "embedded",
      withExtension: "mobileprovision"
    ),
    let data = try? Data(contentsOf: url),
    let start = data.range(of: Data("<?xml".utf8)),
    let end = data.range(
      of: Data("</plist>".utf8),
      options: [],
      in: start.lowerBound..<data.endIndex
    ) else {
      // Ad-hoc/TrollStore-style installations may have no mobile provision.
      // Let NetworkExtension report the authoritative platform result there.
      return nil
    }
    let plistData = Data(data[start.lowerBound..<end.upperBound])
    guard let root = try? PropertyListSerialization.propertyList(
      from: plistData,
      options: [],
      format: nil
    ) as? [String: Any] else {
      return nil
    }
    return root["Entitlements"] as? [String: Any]
  }

  private static func installedExtensionBundle() -> Bundle? {
    guard let plugIns = Bundle.main.builtInPlugInsURL else { return nil }
    return Bundle(
      url: plugIns.appendingPathComponent(Constants.extensionName)
    )
  }

  private func response(
    for manager: NETunnelProviderManager?
  ) -> [String: Any] {
    let status = manager?.connection.status ?? .invalid
    let configured = manager != nil
    let onDemand = manager?.isOnDemandEnabled ?? false
    let enabled = (manager?.isEnabled ?? false) && onDemand
    return [
      "active": status == .connected,
      "status": Self.statusName(status),
      "managedByNeoStation": true,
      "configured": configured,
      // NetworkExtension exposes no standalone permission bit. A manager
      // successfully loaded from preferences is the durable proof that iOS
      // accepted this app's VPN configuration.
      "authorized": configured,
      "enabled": enabled,
      "interfaceAddress": Constants.interfaceAddress,
      "peerAddress": Constants.peerAddress,
      "onDemand": onDemand,
    ]
  }

  private static func configurationFailure(
    _ error: Error
  ) -> NeoStationLocalTunnelError {
    let nsError = error as NSError
    if nsError.domain == NEVPNErrorDomain,
       nsError.code == NEVPNError.configurationReadWriteFailed.rawValue {
      return .permissionDenied
    }
    return .configuration(error.localizedDescription)
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
  case signingMissing
  case activeVPNConflict(String)
  case configuration(String)
  case start(String)
  case stop(String)
  case permissionDenied
  case timeout

  var code: String {
    switch self {
    case .extensionMissing: return "extension_missing"
    case .signingMissing: return "signing_missing"
    case .activeVPNConflict: return "vpn_conflict"
    case .configuration: return "configuration_failed"
    case .start: return "start_failed"
    case .stop: return "stop_failed"
    case .permissionDenied: return "permission_denied"
    case .timeout: return "connection_timeout"
    }
  }

  var errorDescription: String? {
    switch self {
    case .extensionMissing:
      return "The NeoStation local tunnel extension is missing from this installation. Re-sign the complete IPA with app extensions enabled."
    case .signingMissing:
      return "The installed NeoStation signature does not include Apple's packet-tunnel entitlement. Re-sign the complete NeoStation IPA with app extensions enabled and a provisioning profile that authorizes Network Extensions."
    case .activeVPNConflict(let name):
      return "NeoStation cannot start its local JIT tunnel while \(name) is active. Disconnect the other VPN and retry."
    case .configuration(let message):
      return "iOS could not save the NeoStation local tunnel. Confirm the VPN permission and preserve the Network Extension entitlement when signing. Technical detail: \(message)"
    case .start(let message):
      return "The NeoStation local JIT tunnel could not start: \(message)"
    case .stop(let message):
      return "The NeoStation local JIT tunnel could not stop: \(message)"
    case .permissionDenied:
      return "iOS refused the NeoStation VPN configuration. If no native authorization dialog appeared, the signing profile does not authorize the embedded Network Extension."
    case .timeout:
      return "The NeoStation local JIT tunnel did not become ready before the timeout."
    }
  }
}
