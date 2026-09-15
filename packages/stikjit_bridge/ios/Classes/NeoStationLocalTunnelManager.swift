import Foundation
import Network
import NetworkExtension

/// Owns only NeoStation's system VPN configuration while exposing a route-level
/// JIT preflight that can reuse a compatible route created by another app.
///
/// The important distinction is deliberate: a VPN connection is not a JIT
/// route. The RemotePairing endpoint at 10.7.0.1:49152 must answer before an
/// external VPN is accepted. NeoStation never mutates a manager it does not own.
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
    static let jitPort: UInt16 = 49152
    static let extensionName = "NeoStationLocalTunnel.appex"
    static let localizedDescription = "NeoStation Local JIT Tunnel"
    static let serverAddress = "On-device RemotePairing route"
    static let connectionPollInterval: TimeInterval = 0.25
    static let connectionTimeout: TimeInterval = 12
    static let disconnectionTimeout: TimeInterval = 6
    static let routeProbeTimeout: TimeInterval = 1.25
    static let heartbeatInterval: TimeInterval = 1.5
    static let heartbeatMessage = "heartbeat"
  }

  typealias Response = Result<[String: Any], NeoStationLocalTunnelError>

  private var ensureInFlight = false
  private var activeEnsureGeneration: UInt64?
  private var activeEnsureWaiters = [(Response) -> Void]()
  private var queuedEnsureWaiters = [(Response) -> Void]()

  private var disableInFlight = false
  private var disableWaiters = [(Response) -> Void]()

  /// Incremented by every stop request. Async callbacks from an older start
  /// generation must observe the mismatch and are therefore unable to restart
  /// the tunnel after the application asked it to stop.
  private var operationGeneration: UInt64 = 0
  private var stopRequested = false

  private var activeManager: NETunnelProviderManager?
  private var heartbeatTimer: DispatchSourceTimer?

  private init() {}

  /// Compatibility entry point used by the Flutter bridge. Despite the legacy
  /// name, this now guarantees a usable JIT route rather than blindly starting
  /// NeoStation's own packet tunnel.
  func ensureRunning(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      if self.disableInFlight || self.stopRequested {
        self.queuedEnsureWaiters.append(completion)
      } else if self.ensureInFlight {
        self.activeEnsureWaiters.append(completion)
      } else {
        self.queuedEnsureWaiters.append(completion)
        self.beginEnsureIfPossible()
      }
    }
  }

  func status(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      let providerBundleIdentifier = self.providerBundleIdentifier()
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
            providerBundleIdentifier != nil &&
              Self.providerIdentifier(for: $0) == providerBundleIdentifier
          }) ?? matching.first
          completion(.success(self.response(for: manager)))
        }
      }
    }
  }

  /// Stops and disables only NeoStationLocalTunnel. A stop request invalidates
  /// the current start generation immediately, stops an already-created tunnel
  /// synchronously, then persists the disabled profile once any in-flight
  /// preference write has unwound.
  func disable(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      self.disableWaiters.append(completion)
      self.stopRequested = true
      self.operationGeneration &+= 1
      self.stopHeartbeat()
      self.activeManager?.connection.stopVPNTunnel()
      self.beginDisableIfPossible()
    }
  }

  private func beginEnsureIfPossible() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !ensureInFlight,
          !disableInFlight,
          !stopRequested,
          !queuedEnsureWaiters.isEmpty else {
      return
    }

    ensureInFlight = true
    operationGeneration &+= 1
    let generation = operationGeneration
    activeEnsureGeneration = generation
    activeEnsureWaiters.append(contentsOf: queuedEnsureWaiters)
    queuedEnsureWaiters.removeAll(keepingCapacity: true)
    performEnsureJitRoute(generation: generation)
  }

  private func beginDisableIfPossible() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !disableInFlight,
          !ensureInFlight,
          !disableWaiters.isEmpty else {
      return
    }
    disableInFlight = true
    performDisable()
  }

  private func performEnsureJitRoute(generation: UInt64) {
    guard ensureIsCurrent(generation) else {
      finishEnsure(.failure(.cancelled))
      return
    }

    // A manager created in this app process is known to belong to NeoStation;
    // reuse it without misclassifying its endpoint as an external VPN route.
    if let manager = activeManager,
       manager.connection.status == .connected {
      probeJitRoute { available in
        guard self.ensureIsCurrent(generation) else {
          self.finishEnsure(.failure(.cancelled))
          return
        }
        if available {
          self.startHeartbeat(for: manager)
          self.finishEnsure(.success(self.response(for: manager)))
        } else {
          manager.connection.stopVPNTunnel()
          self.activeManager = nil
          self.probeExternalThenEnsureOwned(generation: generation)
        }
      }
      return
    }

    probeExternalThenEnsureOwned(generation: generation)
  }

  private func probeExternalThenEnsureOwned(generation: UInt64) {
    // External route first. This intentionally happens before extension/signing
    // checks and before looking for another app's VPN manager. LocalDevVPN is a
    // valid provider only when the actual StikJIT endpoint answers.
    probeJitRoute { available in
      guard self.ensureIsCurrent(generation) else {
        self.finishEnsure(.failure(.cancelled))
        return
      }
      if available {
        self.stopHeartbeat()
        self.activeManager = nil
        self.finishEnsure(.success(self.externalRouteResponse()))
        return
      }
      self.ensureOwnedTunnel(generation: generation)
    }
  }

  private func ensureOwnedTunnel(generation: UInt64) {
    guard ensureIsCurrent(generation) else {
      finishEnsure(.failure(.cancelled))
      return
    }
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
        guard self.ensureIsCurrent(generation) else {
          self.finishEnsure(.failure(.cancelled))
          return
        }
        if let error {
          self.finishEnsure(.failure(Self.configurationFailure(error)))
          return
        }

        let loaded = managers ?? []
        // The endpoint probe already failed. An active non-NeoStation VPN is
        // therefore not a usable JIT route. Never stop or rewrite that VPN and
        // never attempt to run two VPN providers simultaneously.
        if let conflicting = loaded.first(where: {
          !Self.isOwned(
            $0,
            providerBundleIdentifier: providerBundleIdentifier
          ) && Self.isActive($0.connection.status)
        }) {
          let name = conflicting.localizedDescription ?? "another VPN"
          self.finishEnsure(.failure(.activeVPNConflict(name)))
          return
        }

        let matching = loaded.filter {
          Self.isOwned(
            $0,
            providerBundleIdentifier: providerBundleIdentifier
          )
        }
        let manager = matching.first(where: {
          Self.providerIdentifier(for: $0) == providerBundleIdentifier
        }) ?? matching.first ?? NETunnelProviderManager()
        self.activeManager = manager

        self.removeDuplicateManagers(
          matching.filter { $0 !== manager }
        ) { error in
          guard self.ensureIsCurrent(generation) else {
            self.finishEnsure(.failure(.cancelled))
            return
          }
          if let error {
            self.finishEnsure(.failure(Self.configurationFailure(error)))
            return
          }
          self.configure(
            manager,
            providerBundleIdentifier: providerBundleIdentifier
          )
          self.saveReloadAndStart(manager, generation: generation)
        }
      }
    }
  }

  private func performDisable() {
    let providerBundleIdentifier = providerBundleIdentifier()
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
          providerBundleIdentifier != nil &&
            Self.providerIdentifier(for: $0) == providerBundleIdentifier
        }) ?? matching.first else {
          self.activeManager = nil
          self.finishDisable(.success(self.response(for: nil)))
          return
        }

        self.activeManager = manager
        manager.connection.stopVPNTunnel()
        self.removeDuplicateManagers(
          matching.filter { $0 !== manager }
        ) { error in
          if let error {
            self.finishDisable(.failure(Self.configurationFailure(error)))
            return
          }

          // Persist the exact disabled state before the final stop. No On-Demand
          // rule exists anywhere in NeoStation's configuration path.
          manager.isOnDemandEnabled = false
          manager.onDemandRules = []
          manager.isEnabled = false
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
    manager.onDemandRules = []
    manager.isOnDemandEnabled = false
    manager.isEnabled = true
  }

  private func saveReloadAndStart(
    _ manager: NETunnelProviderManager,
    generation: UInt64
  ) {
    guard ensureIsCurrent(generation) else {
      finishEnsure(.failure(.cancelled))
      return
    }
    manager.saveToPreferences { error in
      DispatchQueue.main.async {
        guard self.ensureIsCurrent(generation) else {
          self.finishEnsure(.failure(.cancelled))
          return
        }
        if let error {
          self.finishEnsure(.failure(Self.configurationFailure(error)))
          return
        }
        manager.loadFromPreferences { error in
          DispatchQueue.main.async {
            guard self.ensureIsCurrent(generation) else {
              self.finishEnsure(.failure(.cancelled))
              return
            }
            if let error {
              self.finishEnsure(.failure(Self.configurationFailure(error)))
              return
            }
            self.activeManager = manager
            self.start(manager, generation: generation)
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

  private func start(
    _ manager: NETunnelProviderManager,
    generation: UInt64
  ) {
    guard ensureIsCurrent(generation) else {
      finishEnsure(.failure(.cancelled))
      return
    }
    if manager.connection.status == .connected {
      verifyOwnedRoute(manager, generation: generation)
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
      generation: generation,
      deadline: Date().addingTimeInterval(Constants.connectionTimeout)
    )
  }

  private func waitUntilConnected(
    _ manager: NETunnelProviderManager,
    generation: UInt64,
    deadline: Date
  ) {
    guard ensureIsCurrent(generation) else {
      finishEnsure(.failure(.cancelled))
      return
    }

    switch manager.connection.status {
    case .connected:
      verifyOwnedRoute(manager, generation: generation)
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
      self.waitUntilConnected(
        manager,
        generation: generation,
        deadline: deadline
      )
    }
  }

  private func verifyOwnedRoute(
    _ manager: NETunnelProviderManager,
    generation: UInt64
  ) {
    probeJitRoute { available in
      guard self.ensureIsCurrent(generation) else {
        self.finishEnsure(.failure(.cancelled))
        return
      }
      guard available else {
        self.disableFailedOwnedRoute(manager, generation: generation)
        return
      }
      self.activeManager = manager
      self.startHeartbeat(for: manager)
      self.finishEnsure(.success(self.response(for: manager)))
    }
  }

  private func disableFailedOwnedRoute(
    _ manager: NETunnelProviderManager,
    generation: UInt64
  ) {
    manager.connection.stopVPNTunnel()
    manager.isOnDemandEnabled = false
    manager.onDemandRules = []
    manager.isEnabled = false
    manager.saveToPreferences { _ in
      DispatchQueue.main.async {
        guard self.ensureIsCurrent(generation) else {
          self.finishEnsure(.failure(.cancelled))
          return
        }
        self.activeManager = nil
        self.finishEnsure(.failure(.routeUnavailable))
      }
    }
  }

  private func waitUntilDisconnected(
    _ manager: NETunnelProviderManager,
    deadline: Date
  ) {
    switch manager.connection.status {
    case .disconnected, .invalid:
      activeManager = nil
      finishDisable(.success(response(for: manager)))
      return
    default:
      break
    }

    guard Date() < deadline else {
      // The profile is already persisted disabled and stopVPNTunnel() was sent.
      // Report the timeout without ever trying to re-enable it.
      activeManager = nil
      finishDisable(.failure(.stop("The VPN connection did not stop.")))
      return
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Constants.connectionPollInterval
    ) {
      self.waitUntilDisconnected(manager, deadline: deadline)
    }
  }

  /// Bounded TCP probe of the real StikJIT/RemotePairing route. This is the
  /// authority for external-route reuse; NEVPNStatus alone is never enough.
  private func probeJitRoute(completion: @escaping (Bool) -> Void) {
    let queue = DispatchQueue(
      label: "com.neogamelab.neostation.localtunnel.route-probe",
      qos: .userInitiated
    )
    let port = NWEndpoint.Port(rawValue: Constants.jitPort)!
    let connection = NWConnection(
      host: NWEndpoint.Host(Constants.peerAddress),
      port: port,
      using: .tcp
    )
    var finished = false
    let finish: (Bool) -> Void = { success in
      guard !finished else { return }
      finished = true
      connection.stateUpdateHandler = nil
      connection.cancel()
      DispatchQueue.main.async {
        completion(success)
      }
    }

    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        finish(true)
      case .failed, .cancelled:
        finish(false)
      default:
        break
      }
    }
    connection.start(queue: queue)
    queue.asyncAfter(
      deadline: .now() + Constants.routeProbeTimeout
    ) {
      finish(false)
    }
  }

  private func startHeartbeat(for manager: NETunnelProviderManager) {
    dispatchPrecondition(condition: .onQueue(.main))
    stopHeartbeat()
    guard manager.connection.status == .connected else { return }
    sendHeartbeat(to: manager)

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(
      deadline: .now() + Constants.heartbeatInterval,
      repeating: Constants.heartbeatInterval,
      leeway: .milliseconds(200)
    )
    timer.setEventHandler { [weak self, weak manager] in
      guard let self, let manager else { return }
      guard manager.connection.status == .connected else {
        self.stopHeartbeat()
        return
      }
      self.sendHeartbeat(to: manager)
    }
    heartbeatTimer = timer
    timer.resume()
  }

  private func stopHeartbeat() {
    dispatchPrecondition(condition: .onQueue(.main))
    heartbeatTimer?.setEventHandler {}
    heartbeatTimer?.cancel()
    heartbeatTimer = nil
  }

  private func sendHeartbeat(to manager: NETunnelProviderManager) {
    guard let session = manager.connection as? NETunnelProviderSession else {
      return
    }
    do {
      try session.sendProviderMessage(Data(Constants.heartbeatMessage.utf8)) { _ in }
    } catch {
      // The watchdog is authoritative. A transient IPC failure simply means
      // the extension will close itself if subsequent heartbeats also fail.
    }
  }

  private func ensureIsCurrent(_ generation: UInt64) -> Bool {
    ensureInFlight &&
      activeEnsureGeneration == generation &&
      operationGeneration == generation &&
      !stopRequested
  }

  private func finishEnsure(_ response: Response) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard ensureInFlight else { return }
    let waiters = activeEnsureWaiters
    activeEnsureWaiters.removeAll(keepingCapacity: true)
    ensureInFlight = false
    activeEnsureGeneration = nil

    if !disableWaiters.isEmpty {
      beginDisableIfPossible()
    } else {
      beginEnsureIfPossible()
    }
    for waiter in waiters {
      waiter(response)
    }
  }

  private func finishDisable(_ response: Response) {
    dispatchPrecondition(condition: .onQueue(.main))
    let waiters = disableWaiters
    disableWaiters.removeAll(keepingCapacity: true)
    disableInFlight = false
    stopRequested = false
    activeManager = nil
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

  private func externalRouteResponse() -> [String: Any] {
    [
      "active": true,
      "status": "externalRoute",
      "managedByNeoStation": false,
      "configured": false,
      "authorized": false,
      "enabled": true,
      "interfaceAddress": NSNull(),
      "peerAddress": Constants.peerAddress,
      "onDemand": false,
    ]
  }

  private func response(
    for manager: NETunnelProviderManager?
  ) -> [String: Any] {
    let status = manager?.connection.status ?? .invalid
    let configured = manager != nil
    let onDemand = manager?.isOnDemandEnabled ?? false
    let enabled = manager?.isEnabled ?? false
    return [
      "active": status == .connected,
      "status": Self.statusName(status),
      "managedByNeoStation": true,
      "configured": configured,
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
    providerBundleIdentifier: String?
  ) -> Bool {
    if let providerBundleIdentifier,
       providerIdentifier(for: manager) == providerBundleIdentifier {
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
  case routeUnavailable
  case configuration(String)
  case start(String)
  case stop(String)
  case permissionDenied
  case timeout
  case cancelled

  var code: String {
    switch self {
    case .extensionMissing: return "extension_missing"
    case .signingMissing: return "signing_missing"
    case .activeVPNConflict: return "vpn_conflict"
    case .routeUnavailable: return "jit_route_unavailable"
    case .configuration: return "configuration_failed"
    case .start: return "start_failed"
    case .stop: return "stop_failed"
    case .permissionDenied: return "permission_denied"
    case .timeout: return "connection_timeout"
    case .cancelled: return "cancelled"
    }
  }

  var errorDescription: String? {
    switch self {
    case .extensionMissing:
      return "The NeoStation local tunnel extension is missing from this installation. Re-sign the complete IPA with app extensions enabled."
    case .signingMissing:
      return "The installed NeoStation signature does not include Apple's packet-tunnel entitlement. Re-sign the complete NeoStation IPA with app extensions enabled and a provisioning profile that authorizes Network Extensions."
    case .activeVPNConflict(let name):
      return "\(name) is active but does not expose the StikJIT route at 10.7.0.1:49152. NeoStation will not modify that VPN or start a second VPN at the same time."
    case .routeUnavailable:
      return "The local tunnel connected, but the StikJIT route at 10.7.0.1:49152 is not reachable."
    case .configuration(let message):
      return "iOS could not save the NeoStation local tunnel. Confirm the VPN permission and preserve the Network Extension entitlement when signing. Technical detail: \(message)"
    case .start(let message):
      return "The NeoStation local JIT tunnel could not start: \(message)"
    case .stop(let message):
      return "The NeoStation local JIT tunnel could not stop: \(message)"
    case .permissionDenied:
      return "iOS refused the NeoStation VPN configuration. If no native authorization dialog appeared, the signing profile does not authorize the embedded Network Extension."
    case .timeout:
      return "The NeoStation local JIT tunnel did not become ready before the bounded connection timeout."
    case .cancelled:
      return "The NeoStation local JIT route activation was cancelled because the application requested the tunnel to stop."
    }
  }
}
