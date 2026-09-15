import Foundation
import Network
import NetworkExtension

/// Owns only NeoStation's VPN. A VPN status is not proof of a working JIT route:
/// the RemotePairing TCP endpoint must answer before any preflight succeeds.
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
    static let disconnectErrorTimeout: TimeInterval = 0.75
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
  private var operationGeneration: UInt64 = 0
  private var stopRequested = false
  private var activeManager: NETunnelProviderManager?
  private var heartbeatTimer: DispatchSourceTimer?
  private let heartbeatQueue = DispatchQueue(
    label: "com.neogamelab.neostation.localtunnel.heartbeat", qos: .utility
  )
  private var trace = [String]()
  private init() {}

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
      let identifier = self.providerBundleIdentifier()
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        DispatchQueue.main.async {
          if let error {
            completion(.failure(Self.configurationFailure(error)))
            return
          }
          let matching = (managers ?? []).filter {
            Self.isOwned($0, providerBundleIdentifier: identifier)
          }
          let manager = matching.first(where: { Self.isActive($0.connection.status) }) ??
            matching.first(where: { identifier != nil && Self.providerIdentifier(for: $0) == identifier }) ??
            matching.first
          completion(.success(self.response(for: manager)))
        }
      }
    }
  }

  func disable(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      let cancelledWaiters = self.queuedEnsureWaiters
      self.queuedEnsureWaiters.removeAll(keepingCapacity: true)
      self.disableWaiters.append(completion)
      self.stopRequested = true
      self.operationGeneration &+= 1
      self.stopHeartbeat()
      self.activeManager?.connection.stopVPNTunnel()
      self.beginDisableIfPossible()
      for waiter in cancelledWaiters { waiter(.failure(.cancelled)) }
    }
  }

  private func beginEnsureIfPossible() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !ensureInFlight, !disableInFlight, !stopRequested,
          !queuedEnsureWaiters.isEmpty else { return }
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
    guard !disableInFlight, !ensureInFlight, !disableWaiters.isEmpty else { return }
    disableInFlight = true
    performDisable()
  }

  private func performEnsureJitRoute(generation: UInt64) {
    trace = ["generation=\(generation)"]
    guard ensureIsCurrent(generation) else {
      finishEnsure(.failure(.cancelled), generation: generation)
      return
    }
    if let manager = activeManager, manager.connection.status == .connected {
      startHeartbeat(for: manager)
      probeJitRoute { available in
        guard self.ensureIsCurrent(generation) else {
          self.finishEnsure(.failure(.cancelled), generation: generation)
          return
        }
        if available {
          self.finishEnsure(.success(self.response(for: manager, routeVerified: true)), generation: generation)
        } else {
          // Do not probe an owned route while its asynchronous stop is still
          // draining: that route could be mistaken for a surviving external VPN.
          self.stopHeartbeat()
          manager.connection.stopVPNTunnel()
          self.waitForOwnedStop(
            manager, generation: generation,
            deadline: ProcessInfo.processInfo.systemUptime + Constants.disconnectionTimeout
          ) {
            self.activeManager = nil
            self.probeExternalThenEnsureOwned(generation: generation)
          }
        }
      }
      return
    }
    probeExternalThenEnsureOwned(generation: generation)
  }

  private func probeExternalThenEnsureOwned(generation: UInt64) {
    // Keep the external probe before signing/extension checks. A working
    // LocalDevVPN route must remain usable without our extension entitlement.
    probeJitRoute { available in
      guard self.ensureIsCurrent(generation) else {
        self.finishEnsure(.failure(.cancelled), generation: generation)
        return
      }
      self.trace.append("externalProbe=\(available)")
      if available {
        self.stopHeartbeat()
        self.activeManager = nil
        self.finishEnsure(.success(self.externalRouteResponse()), generation: generation)
        return
      }
      self.ensureOwnedTunnel(generation: generation)
    }
  }

  private func ensureOwnedTunnel(generation: UInt64) {
    guard ensureIsCurrent(generation) else {
      finishEnsure(.failure(.cancelled), generation: generation)
      return
    }
    guard let providerBundleIdentifier = providerBundleIdentifier() else {
      finishEnsure(.failure(.extensionMissing), generation: generation)
      return
    }
    if let failure = Self.signingCapabilityFailure() {
      finishEnsure(.failure(failure), generation: generation)
      return
    }
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      DispatchQueue.main.async {
        guard self.ensureIsCurrent(generation) else {
          self.finishEnsure(.failure(.cancelled), generation: generation)
          return
        }
        if let error {
          self.finishEnsure(.failure(Self.configurationFailure(error)), generation: generation)
          return
        }
        let loaded = managers ?? []
        if let conflicting = loaded.first(where: {
          !Self.isOwned($0, providerBundleIdentifier: providerBundleIdentifier) &&
            Self.isActive($0.connection.status)
        }) {
          self.finishEnsure(.failure(.activeVPNConflict(conflicting.localizedDescription ?? "another VPN")), generation: generation)
          return
        }
        let matching = loaded.filter {
          Self.isOwned($0, providerBundleIdentifier: providerBundleIdentifier)
        }
        let manager = matching.first(where: {
          Self.providerIdentifier(for: $0) == providerBundleIdentifier &&
            Self.isActive($0.connection.status)
        }) ?? matching.first(where: {
          Self.providerIdentifier(for: $0) == providerBundleIdentifier
        }) ?? matching.first ?? NETunnelProviderManager()
        self.activeManager = manager
        self.removeDuplicateManagers(matching.filter { $0 !== manager }) { error in
          guard self.ensureIsCurrent(generation) else {
            self.finishEnsure(.failure(.cancelled), generation: generation)
            return
          }
          if let error {
            self.finishEnsure(.failure(Self.configurationFailure(error)), generation: generation)
            return
          }
          self.configure(manager, providerBundleIdentifier: providerBundleIdentifier)
          self.saveReloadAndStart(manager, generation: generation)
        }
      }
    }
  }

  private func performDisable() {
    let identifier = providerBundleIdentifier()
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      DispatchQueue.main.async {
        if let error {
          self.finishDisable(.failure(Self.configurationFailure(error)))
          return
        }
        let matching = (managers ?? []).filter {
          Self.isOwned($0, providerBundleIdentifier: identifier)
        }
        guard let manager = matching.first(where: { Self.isActive($0.connection.status) }) ??
          matching.first(where: { identifier != nil && Self.providerIdentifier(for: $0) == identifier }) ??
          matching.first else {
          self.activeManager = nil
          self.finishDisable(.success(self.response(for: nil)))
          return
        }
        self.activeManager = manager
        manager.connection.stopVPNTunnel()
        self.removeDuplicateManagers(matching.filter { $0 !== manager }) { error in
          if let error {
            self.finishDisable(.failure(Self.configurationFailure(error)))
            return
          }
          manager.isOnDemandEnabled = false
          manager.onDemandRules = []
          manager.isEnabled = false
          self.saveReloadAndStop(manager)
        }
      }
    }
  }

  private func removeDuplicateManagers(
    _ managers: [NETunnelProviderManager], completion: @escaping (Error?) -> Void
  ) {
    guard let manager = managers.first else { completion(nil); return }
    // Callers supply owned managers only. Neutralize old On-Demand profiles
    // before removal as well as the selected profile, never a third-party VPN.
    manager.isOnDemandEnabled = false
    manager.onDemandRules = []
    manager.isEnabled = false
    manager.connection.stopVPNTunnel()
    manager.saveToPreferences { error in
      DispatchQueue.main.async {
        if let error { completion(error); return }
        manager.removeFromPreferences { error in
          DispatchQueue.main.async {
            if let error { completion(error); return }
            self.removeDuplicateManagers(Array(managers.dropFirst()), completion: completion)
          }
        }
      }
    }
  }

  private func configure(_ manager: NETunnelProviderManager, providerBundleIdentifier: String) {
    let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol ?? NETunnelProviderProtocol()
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

  private func saveReloadAndStart(_ manager: NETunnelProviderManager, generation: UInt64) {
    guard ensureIsCurrent(generation) else {
      finishEnsure(.failure(.cancelled), generation: generation); return
    }
    manager.saveToPreferences { error in
      DispatchQueue.main.async {
        guard self.ensureIsCurrent(generation) else {
          self.finishEnsure(.failure(.cancelled), generation: generation); return
        }
        if let error {
          self.finishEnsure(.failure(Self.configurationFailure(error)), generation: generation); return
        }
        manager.loadFromPreferences { error in
          DispatchQueue.main.async {
            guard self.ensureIsCurrent(generation) else {
              self.finishEnsure(.failure(.cancelled), generation: generation); return
            }
            if let error {
              self.finishEnsure(.failure(Self.configurationFailure(error)), generation: generation); return
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
        if let error { self.finishDisable(.failure(Self.configurationFailure(error))); return }
        manager.loadFromPreferences { error in
          DispatchQueue.main.async {
            if let error { self.finishDisable(.failure(Self.configurationFailure(error))); return }
            manager.connection.stopVPNTunnel()
            self.waitUntilDisconnected(
              manager, deadline: ProcessInfo.processInfo.systemUptime + Constants.disconnectionTimeout
            )
          }
        }
      }
    }
  }

  private func start(_ manager: NETunnelProviderManager, generation: UInt64) {
    guard ensureIsCurrent(generation) else {
      finishEnsure(.failure(.cancelled), generation: generation); return
    }
    trace.append("startStatus=\(Self.statusName(manager.connection.status))")
    if manager.connection.status == .disconnecting {
      // startVPNTunnel during disconnecting may be ignored by the system.
      // Wait for that transition rather than timing out a start never accepted.
      waitForOwnedStop(
        manager, generation: generation,
        deadline: ProcessInfo.processInfo.systemUptime + Constants.disconnectionTimeout
      ) { self.start(manager, generation: generation) }
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
        disableFailedOwnedRoute(manager, generation: generation, failure: .start(Self.errorDetail(error)))
        return
      }
    }
    waitUntilConnected(
      manager, generation: generation,
      deadline: ProcessInfo.processInfo.systemUptime + Constants.connectionTimeout,
      observedConnecting: false
    )
  }

  private func waitForOwnedStop(
    _ manager: NETunnelProviderManager, generation: UInt64,
    deadline: TimeInterval, completion: @escaping () -> Void
  ) {
    guard ensureIsCurrent(generation) else {
      finishEnsure(.failure(.cancelled), generation: generation); return
    }
    if manager.connection.status == .disconnected || manager.connection.status == .invalid {
      completion()
      return
    }
    guard ProcessInfo.processInfo.systemUptime < deadline else {
      failConnection(manager, generation: generation, timedOut: true)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.connectionPollInterval) {
      self.waitForOwnedStop(manager, generation: generation, deadline: deadline, completion: completion)
    }
  }

  private func waitUntilConnected(
    _ manager: NETunnelProviderManager, generation: UInt64,
    deadline: TimeInterval, observedConnecting: Bool
  ) {
    guard ensureIsCurrent(generation) else {
      finishEnsure(.failure(.cancelled), generation: generation); return
    }
    let status = manager.connection.status
    switch status {
    case .connected:
      verifyOwnedRoute(manager, generation: generation)
      return
    case .invalid:
      failConnection(manager, generation: generation, timedOut: false)
      return
    case .disconnected where observedConnecting:
      // The provider actually stopped; do not hide its error behind 12 seconds
      // of polling a terminal state.
      failConnection(manager, generation: generation, timedOut: false)
      return
    default: break
    }
    guard ProcessInfo.processInfo.systemUptime < deadline else {
      failConnection(manager, generation: generation, timedOut: true)
      return
    }
    let observed = observedConnecting || status == .connecting || status == .reasserting
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.connectionPollInterval) {
      self.waitUntilConnected(
        manager, generation: generation, deadline: deadline, observedConnecting: observed
      )
    }
  }

  private func failConnection(
    _ manager: NETunnelProviderManager, generation: UInt64, timedOut: Bool
  ) {
    let status = Self.statusName(manager.connection.status)
    // The disconnect-error API can itself be delayed. Settle once, bounded,
    // and query BEFORE cleanup so our stop does not overwrite the useful error.
    var completed = false
    let complete: (Error?) -> Void = { error in
      guard !completed else { return }
      completed = true
      guard self.ensureIsCurrent(generation) else {
        self.finishEnsure(.failure(.cancelled), generation: generation); return
      }
      let details = "status=\(status); provider=\(Self.providerIdentifier(for: manager) ?? "missing"); " +
        "trace=\(self.trace.joined(separator: ",")); " +
        (error.map(Self.errorDetail) ?? "iOS supplied no disconnect error")
      self.disableFailedOwnedRoute(
        manager, generation: generation,
        failure: timedOut ? .timeout(details) : .start(details)
      )
    }
    manager.connection.fetchLastDisconnectError { error in
      DispatchQueue.main.async { complete(error) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.disconnectErrorTimeout) {
      complete(nil)
    }
  }

  private func verifyOwnedRoute(_ manager: NETunnelProviderManager, generation: UInt64) {
    // Keep the provider alive while the real endpoint is being verified; the
    // provider watchdog must not depend on Flutter/UI-thread responsiveness.
    startHeartbeat(for: manager)
    probeJitRoute { available in
      guard self.ensureIsCurrent(generation) else {
        self.finishEnsure(.failure(.cancelled), generation: generation); return
      }
      guard available, manager.connection.status == .connected else {
        self.disableFailedOwnedRoute(manager, generation: generation, failure: .routeUnavailable)
        return
      }
      self.activeManager = manager
      self.finishEnsure(.success(self.response(for: manager, routeVerified: true)), generation: generation)
    }
  }

  private func disableFailedOwnedRoute(
    _ manager: NETunnelProviderManager, generation: UInt64,
    failure: NeoStationLocalTunnelError
  ) {
    guard ensureIsCurrent(generation) else {
      finishEnsure(.failure(.cancelled), generation: generation); return
    }
    stopHeartbeat()
    manager.isOnDemandEnabled = false
    manager.onDemandRules = []
    manager.isEnabled = false
    manager.connection.stopVPNTunnel()
    manager.saveToPreferences { error in
      DispatchQueue.main.async {
        guard self.ensureIsCurrent(generation) else {
          self.finishEnsure(.failure(.cancelled), generation: generation); return
        }
        // No start remains outstanding after the error. A later legitimate
        // ensure may enable the profile anew; no automatic retry is queued.
        manager.connection.stopVPNTunnel()
        self.activeManager = nil
        if let error {
          self.finishEnsure(.failure(.stop("\(failure.localizedDescription); cleanup: \(Self.errorDetail(error))")), generation: generation)
        } else {
          self.finishEnsure(.failure(failure), generation: generation)
        }
      }
    }
  }

  private func waitUntilDisconnected(_ manager: NETunnelProviderManager, deadline: TimeInterval) {
    switch manager.connection.status {
    case .disconnected, .invalid:
      activeManager = nil
      finishDisable(.success(response(for: manager)))
      return
    default: break
    }
    guard ProcessInfo.processInfo.systemUptime < deadline else {
      activeManager = nil
      finishDisable(.failure(.stop("The VPN connection did not stop; status=\(Self.statusName(manager.connection.status)).")))
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.connectionPollInterval) {
      self.waitUntilDisconnected(manager, deadline: deadline)
    }
  }

  private func probeJitRoute(completion: @escaping (Bool) -> Void) {
    let queue = DispatchQueue(label: "com.neogamelab.neostation.localtunnel.route-probe", qos: .userInitiated)
    let connection = NWConnection(
      host: NWEndpoint.Host(Constants.peerAddress),
      port: NWEndpoint.Port(rawValue: Constants.jitPort)!, using: .tcp
    )
    var finished = false
    let finish: (Bool) -> Void = { success in
      guard !finished else { return }
      finished = true
      connection.stateUpdateHandler = nil
      connection.cancel()
      DispatchQueue.main.async { completion(success) }
    }
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready: finish(true)
      case .failed, .cancelled: finish(false)
      default: break
      }
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + Constants.routeProbeTimeout) { finish(false) }
  }

  private func startHeartbeat(for manager: NETunnelProviderManager) {
    dispatchPrecondition(condition: .onQueue(.main))
    stopHeartbeat()
    guard manager.connection.status == .connected else { return }
    // Sending from a dedicated queue avoids an accidental watchdog expiry
    // during synchronous work in the native game controller on the main thread.
    let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
    timer.schedule(deadline: .now(), repeating: Constants.heartbeatInterval, leeway: .milliseconds(200))
    timer.setEventHandler { [weak manager] in
      guard let manager, manager.connection.status == .connected else { return }
      Self.sendHeartbeat(to: manager)
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

  private static func sendHeartbeat(to manager: NETunnelProviderManager) {
    guard let session = manager.connection as? NETunnelProviderSession else { return }
    do {
      try session.sendProviderMessage(Data(Constants.heartbeatMessage.utf8)) { _ in }
    } catch {
      // A failed IPC does not pretend to renew the lease. The independent
      // extension watchdog remains authoritative after app suspension/crash.
    }
  }

  private func ensureIsCurrent(_ generation: UInt64) -> Bool {
    ensureInFlight && activeEnsureGeneration == generation &&
      operationGeneration == generation && !stopRequested
  }

  private func finishEnsure(_ response: Response, generation: UInt64? = nil) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard ensureInFlight else { return }
    // A bounded diagnostic callback from an older operation must not settle a
    // newer operation that started after it. Queue tests still use the default.
    if let generation, activeEnsureGeneration != generation { return }
    let waiters = activeEnsureWaiters
    activeEnsureWaiters.removeAll(keepingCapacity: true)
    ensureInFlight = false
    activeEnsureGeneration = nil
    if !disableWaiters.isEmpty { beginDisableIfPossible() }
    else { beginEnsureIfPossible() }
    for waiter in waiters { waiter(response) }
  }

  private func finishDisable(_ response: Response) {
    dispatchPrecondition(condition: .onQueue(.main))
    let waiters = disableWaiters
    disableWaiters.removeAll(keepingCapacity: true)
    disableInFlight = false
    stopRequested = false
    activeManager = nil
    beginEnsureIfPossible()
    for waiter in waiters { waiter(response) }
  }

  private func providerBundleIdentifier() -> String? {
    guard let bundle = Self.installedExtensionBundle(),
          let identifier = bundle.bundleIdentifier, !identifier.isEmpty else { return nil }
    return identifier
  }

  private static func signingCapabilityFailure() -> NeoStationLocalTunnelError? {
    guard let bundle = installedExtensionBundle() else { return .extensionMissing }
    for bundle in [Bundle.main, bundle] {
      if let values = provisioningEntitlements(in: bundle),
         !entitlement(values, key: "com.apple.developer.networking.networkextension", contains: "packet-tunnel-provider") {
        return .signingMissing
      }
    }
    return nil
  }

  private static func entitlement(_ entitlements: [String: Any], key: String, contains value: String) -> Bool {
    if let values = entitlements[key] as? [String] { return values.contains(value) }
    return (entitlements[key] as? String) == value
  }

  private static func provisioningEntitlements(in bundle: Bundle) -> [String: Any]? {
    guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
          let data = try? Data(contentsOf: url),
          let start = data.range(of: Data("<?xml".utf8)),
          let end = data.range(of: Data("</plist>".utf8), options: [], in: start.lowerBound..<data.endIndex)
    else { return nil }
    guard let root = try? PropertyListSerialization.propertyList(
      from: Data(data[start.lowerBound..<end.upperBound]), options: [], format: nil
    ) as? [String: Any] else { return nil }
    return root["Entitlements"] as? [String: Any]
  }

  private static func installedExtensionBundle() -> Bundle? {
    guard let plugIns = Bundle.main.builtInPlugInsURL else { return nil }
    return Bundle(url: plugIns.appendingPathComponent(Constants.extensionName))
  }

  private func externalRouteResponse() -> [String: Any] {
    ["active": true, "status": "externalRoute", "managedByNeoStation": false,
     "configured": false, "authorized": false, "enabled": true,
     "interfaceAddress": NSNull(), "peerAddress": Constants.peerAddress,
     "onDemand": false, "routeVerified": true]
  }

  private func response(for manager: NETunnelProviderManager?, routeVerified: Bool = false) -> [String: Any] {
    let status = manager?.connection.status ?? .invalid
    return [
      "active": status == .connected, "status": Self.statusName(status),
      "managedByNeoStation": true, "configured": manager != nil,
      "authorized": manager != nil, "enabled": manager?.isEnabled ?? false,
      "interfaceAddress": Constants.interfaceAddress, "peerAddress": Constants.peerAddress,
      "onDemand": manager?.isOnDemandEnabled ?? false, "routeVerified": routeVerified,
    ]
  }

  private static func configurationFailure(_ error: Error) -> NeoStationLocalTunnelError {
    let error = error as NSError
    if error.domain == NEVPNErrorDomain,
       error.code == NEVPNError.configurationReadWriteFailed.rawValue { return .permissionDenied }
    return .configuration(errorDetail(error))
  }

  private static func errorDetail(_ error: Error) -> String {
    let error = error as NSError
    var detail = "\(error.domain)(\(error.code)): \(error.localizedDescription)"
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
      detail += "; underlying=\(underlying.domain)(\(underlying.code)): \(underlying.localizedDescription)"
    }
    return detail
  }

  private static func providerIdentifier(for manager: NETunnelProviderManager) -> String? {
    (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
  }

  private static func isOwned(_ manager: NETunnelProviderManager, providerBundleIdentifier: String?) -> Bool {
    if let providerBundleIdentifier, providerIdentifier(for: manager) == providerBundleIdentifier { return true }
    guard manager.localizedDescription == Constants.localizedDescription,
          let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
          configuration[Constants.schemaVersionKey] as? Int == Constants.schemaVersion else { return false }
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
  case extensionMissing, signingMissing, routeUnavailable, permissionDenied
  case cancelled
  case activeVPNConflict(String), configuration(String), start(String), stop(String), timeout(String)

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
      return "iOS could not save the NeoStation local tunnel. Technical detail: \(message)"
    case .start(let message):
      return "The NeoStation local JIT tunnel could not start: \(message)"
    case .stop(let message):
      return "The NeoStation local JIT tunnel could not stop: \(message)"
    case .permissionDenied:
      return "iOS refused the NeoStation VPN configuration. If no native authorization dialog appeared, the signing profile does not authorize the embedded Network Extension."
    case .timeout(let message):
      return "The NeoStation local JIT tunnel did not become ready before the bounded connection timeout. \(message)"
    case .cancelled:
      return "The NeoStation local JIT route activation was cancelled because the application requested the tunnel to stop."
    }
  }
}
