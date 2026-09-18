import Foundation
import Network
import NetworkExtension

/// Single-source controller for NeoStation's integrated local JIT VPN.
///
/// Invariants:
/// - Only explicit Settings ON/OFF may start or stop NeoStation's VPN.
/// - JIT/game preflight is read-only and never mutates any VPN profile.
/// - A timeout, RemotePairing failure, provider diagnostic failure, app lifecycle
///   transition or emulator failure can report an error, but can never turn an
///   already-active NeoStation tunnel off.
@available(iOS 17.4, *)
final class NeoStationLocalTunnelManager {
  static let shared = NeoStationLocalTunnelManager()

  private enum Constants {
    static let schemaVersion = 277
    static let schemaVersionKey = "schemaVersion"
    static let interfaceAddressKey = "interfaceAddress"
    static let peerAddressKey = "peerAddress"
    static let installationTokenKey = "installationToken"
    static let installationTokenDefaultsKey =
      "NeoStationLocalTunnel.installationToken"
    static let interfaceAddress = "10.7.1.1"
    static let peerAddress = "10.7.0.1"
    static let jitPort: UInt16 = 49152
    static let extensionName = "NeoStationLocalTunnel.appex"
    static let localizedDescription = "NeoStation Local JIT Tunnel"
    static let serverAddress = "10.7.0.1"
    static let routeProbeTimeout: TimeInterval = 1.25
    static let connectionPollInterval: TimeInterval = 0.20
    static let handoffSettleDelay: TimeInterval = 1.0
    static let activationTimeout: TimeInterval = 45
    static let stopTimeout: TimeInterval = 12
  }

  typealias Response = Result<[String: Any], NeoStationLocalTunnelError>

  private final class Command {
    let id: UInt64
    let intent: String
    var completed = false
    var waiters: [(Response) -> Void]
    var timeout: DispatchWorkItem?

    init(id: UInt64, intent: String, completion: @escaping (Response) -> Void) {
      self.id = id
      self.intent = intent
      self.waiters = [completion]
    }
  }

  private var serial: UInt64 = 0
  private var command: Command?
  private var activeManager: NETunnelProviderManager?
  private var lastFailure: NeoStationLocalTunnelError?

  private init() {}

  // MARK: - Read-only JIT preflight

  func ensureRunning(completion: @escaping (Response) -> Void) {
    probeJitRoute { reachable in
      guard reachable else {
        completion(.failure(.routeUnavailable))
        return
      }

      NETunnelProviderManager.loadAllFromPreferences { managers, _ in
        DispatchQueue.main.async {
          let identifier = self.providerBundleIdentifier()
          let owned = (managers ?? []).filter {
            Self.isOwned($0, providerBundleIdentifier: identifier)
          }
          let manager = owned.first(where: { Self.isActive($0.connection.status) })
          if let manager { self.activeManager = manager }
          completion(.success(self.routeResponse(for: manager)))
        }
      }
    }
  }

  // MARK: - Status

  func status(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      let identifier = self.providerBundleIdentifier()
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        DispatchQueue.main.async {
          if let error {
            completion(.failure(Self.configurationFailure(error)))
            return
          }
          let owned = (managers ?? []).filter {
            Self.isOwned($0, providerBundleIdentifier: identifier)
          }
          let manager = Self.preferredManager(
            in: owned,
            providerBundleIdentifier: identifier
          )
          self.activeManager = manager
          completion(.success(self.response(for: manager)))
        }
      }
    }
  }

  // MARK: - Explicit Settings ON

  func enableOwned(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      if let command = self.command, command.intent == "enable" {
        command.waiters.append(completion)
        return
      }
      let command = self.beginCommand(
        intent: "enable",
        timeout: Constants.activationTimeout,
        completion: completion
      )
      self.loadAndEnable(command)
    }
  }

  private func loadAndEnable(_ command: Command) {
    guard isCurrent(command) else { return }
    guard let providerIdentifier = providerBundleIdentifier() else {
      finish(command, .failure(.extensionMissing))
      return
    }
    if let error = Self.signingCapabilityFailure() {
      finish(command, .failure(error))
      return
    }

    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      DispatchQueue.main.async {
        guard self.isCurrent(command) else { return }
        if let error {
          self.finish(command, .failure(Self.configurationFailure(error)))
          return
        }

        let allManagers = managers ?? []
        let owned = allManagers.filter {
          Self.isOwned($0, providerBundleIdentifier: providerIdentifier)
        }

        // LocalDevVPN and NeoStation are both packet-tunnel VPNs. Explicit ON
        // must hand off from any already-active foreign tunnel before asking
        // iOS to start NeoStation's tunnel. stopVPNTunnel() is asynchronous, so
        // wait for the foreign connection to be fully quiescent before retrying.
        let foreignActive = allManagers.filter {
          !Self.isOwned($0, providerBundleIdentifier: providerIdentifier) &&
            Self.needsHandoff($0.connection.status)
        }
        if !foreignActive.isEmpty {
          self.stopForeignManagersForHandoff(
            foreignActive,
            index: 0,
            command: command
          ) {
            DispatchQueue.main.asyncAfter(
              deadline: .now() + Constants.handoffSettleDelay
            ) {
              self.loadAndEnable(command)
            }
          }
          return
        }

        // A NETunnelProviderManager profile can survive a sideload uninstall
        // even though NeoStation receives a new application container/signing
        // instance. Never reuse such a stale profile for a new installation.
        // The token lives in this app container and is copied into the system
        // VPN profile, so an ordinary in-place update keeps the same profile
        // while a reinstall recreates it exactly once.
        let token = self.installationToken()
        let current = owned.filter {
          Self.installationToken(for: $0) == token
        }
        let stale = owned.filter {
          Self.installationToken(for: $0) != token
        }

        let manager = Self.preferredManager(
          in: current,
          providerBundleIdentifier: providerIdentifier
        ) ?? NETunnelProviderManager()
        self.activeManager = manager

        let duplicates = current.filter { $0 !== manager }
        self.disableAndRemoveDuplicates(
          stale + duplicates,
          index: 0,
          command: command
        ) {
          self.recoverOwnedTransitionIfNeeded(
            manager,
            command: command
          ) {
            self.persistAndStart(
              manager,
              providerIdentifier: providerIdentifier,
              installationToken: token,
              command: command
            )
          }
        }
      }
    }
  }

  private func stopForeignManagersForHandoff(
    _ managers: [NETunnelProviderManager],
    index: Int,
    command: Command,
    completion: @escaping () -> Void
  ) {
    guard isCurrent(command) else { return }
    guard index < managers.count else {
      completion()
      return
    }

    let manager = managers[index]
    if Self.needsStopRequest(manager.connection.status) {
      manager.connection.stopVPNTunnel()
    }
    waitUntilQuiescent(manager, command: command, settle: false) {
      self.stopForeignManagersForHandoff(
        managers,
        index: index + 1,
        command: command,
        completion: completion
      )
    }
  }

  private func recoverOwnedTransitionIfNeeded(
    _ manager: NETunnelProviderManager,
    command: Command,
    completion: @escaping () -> Void
  ) {
    guard isCurrent(command) else { return }

    switch manager.connection.status {
    case .connecting, .reasserting, .disconnecting:
      // This can be left behind when an earlier explicit ON collided with an
      // already-active LocalDevVPN. A new explicit ON is allowed to recover our
      // own unfinished transition before making a fresh start request.
      if Self.needsStopRequest(manager.connection.status) {
        manager.connection.stopVPNTunnel()
      }
      waitUntilQuiescent(manager, command: command, settle: true, completion)
    default:
      completion()
    }
  }

  private func waitUntilQuiescent(
    _ manager: NETunnelProviderManager,
    command: Command,
    settle: Bool,
    _ completion: @escaping () -> Void
  ) {
    guard isCurrent(command) else { return }

    if Self.isQuiescent(manager.connection.status) {
      if settle {
        DispatchQueue.main.asyncAfter(
          deadline: .now() + Constants.handoffSettleDelay
        ) {
          guard self.isCurrent(command) else { return }
          completion()
        }
      } else {
        completion()
      }
      return
    }

    DispatchQueue.main.asyncAfter(
      deadline: .now() + Constants.connectionPollInterval
    ) {
      self.waitUntilQuiescent(
        manager,
        command: command,
        settle: settle,
        completion
      )
    }
  }

  private func persistAndStart(
    _ manager: NETunnelProviderManager,
    providerIdentifier: String,
    installationToken: String,
    command: Command
  ) {
    guard isCurrent(command) else { return }

    configure(
      manager,
      providerIdentifier: providerIdentifier,
      installationToken: installationToken
    )
    manager.saveToPreferences { error in
      DispatchQueue.main.async {
        guard self.isCurrent(command) else { return }
        if let error {
          self.finish(command, .failure(Self.configurationFailure(error)))
          return
        }

        manager.loadFromPreferences { error in
          DispatchQueue.main.async {
            guard self.isCurrent(command) else { return }
            if let error {
              self.finish(command, .failure(Self.configurationFailure(error)))
              return
            }
            self.activeManager = manager
            self.startIfNeeded(manager, command: command)
          }
        }
      }
    }
  }

  private func startIfNeeded(
    _ manager: NETunnelProviderManager,
    command: Command
  ) {
    guard isCurrent(command) else { return }

    switch manager.connection.status {
    case .connected:
      finish(command, .success(response(for: manager)))
      return
    case .connecting, .reasserting:
      waitUntilConnected(
        manager,
        command: command,
        observedConnecting: true
      )
      return
    case .disconnecting:
      DispatchQueue.main.asyncAfter(
        deadline: .now() + Constants.connectionPollInterval
      ) {
        self.startIfNeeded(manager, command: command)
      }
      return
    case .disconnected, .invalid:
      break
    @unknown default:
      finish(
        command,
        .failure(.start("Unknown NetworkExtension state before activation."))
      )
      return
    }

    do {
      try manager.connection.startVPNTunnel(options: [
        Constants.interfaceAddressKey: Constants.interfaceAddress as NSString,
        Constants.peerAddressKey: Constants.peerAddress as NSString,
      ])
    } catch {
      finish(command, .failure(.start(Self.errorDetail(error))))
      return
    }

    waitUntilConnected(
      manager,
      command: command,
      observedConnecting: false
    )
  }

  private func waitUntilConnected(
    _ manager: NETunnelProviderManager,
    command: Command,
    observedConnecting: Bool
  ) {
    guard isCurrent(command) else { return }

    let status = manager.connection.status
    switch status {
    case .connected:
      activeManager = manager
      finish(command, .success(response(for: manager)))
      return
    case .invalid:
      finish(
        command,
        .failure(.start("The integrated VPN entered an invalid state."))
      )
      return
    case .disconnected where observedConnecting:
      // Only a return to disconnected AFTER iOS entered connecting/reasserting
      // proves that this activation attempt actually stopped. Immediately after
      // startVPNTunnel(), NEVPNConnection may still report its previous
      // disconnected state for a short time.
      manager.connection.fetchLastDisconnectError { error in
        DispatchQueue.main.async {
          guard self.isCurrent(command) else { return }
          let detail = error.map(Self.errorDetail) ??
            "iOS stopped the tunnel after activation began without a disconnect error."
          self.finish(command, .failure(.start(detail)))
        }
      }
      return
    default:
      break
    }

    let observed =
      observedConnecting ||
      status == .connecting ||
      status == .reasserting

    DispatchQueue.main.asyncAfter(
      deadline: .now() + Constants.connectionPollInterval
    ) {
      self.waitUntilConnected(
        manager,
        command: command,
        observedConnecting: observed
      )
    }
  }

  // MARK: - Explicit Settings OFF

  func disable(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      if let command = self.command, command.intent == "disable" {
        command.waiters.append(completion)
        return
      }
      let command = self.beginCommand(
        intent: "disable",
        timeout: Constants.stopTimeout,
        completion: completion
      )
      self.loadAndDisable(command)
    }
  }

  private func loadAndDisable(_ command: Command) {
    guard isCurrent(command) else { return }
    let identifier = providerBundleIdentifier()

    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      DispatchQueue.main.async {
        guard self.isCurrent(command) else { return }
        if let error {
          self.finish(command, .failure(Self.configurationFailure(error)))
          return
        }

        let owned = (managers ?? []).filter {
          Self.isOwned($0, providerBundleIdentifier: identifier)
        }
        guard !owned.isEmpty else {
          self.activeManager = nil
          self.finish(command, .success(self.response(for: nil)))
          return
        }
        self.stopOwnedManagers(owned, index: 0, command: command)
      }
    }
  }

  private func stopOwnedManagers(
    _ managers: [NETunnelProviderManager],
    index: Int,
    command: Command
  ) {
    guard isCurrent(command) else { return }
    guard index < managers.count else {
      waitUntilAllStopped(managers, command: command)
      return
    }

    let manager = managers[index]
    manager.connection.stopVPNTunnel()
    manager.isOnDemandEnabled = false
    manager.onDemandRules = []
    manager.isEnabled = false

    manager.saveToPreferences { error in
      DispatchQueue.main.async {
        guard self.isCurrent(command) else { return }
        if let error {
          self.finish(command, .failure(Self.configurationFailure(error)))
          return
        }
        self.stopOwnedManagers(
          managers,
          index: index + 1,
          command: command
        )
      }
    }
  }

  private func waitUntilAllStopped(
    _ managers: [NETunnelProviderManager],
    command: Command
  ) {
    guard isCurrent(command) else { return }

    if managers.allSatisfy({
      !Self.isActive($0.connection.status) &&
        $0.connection.status != .disconnecting
    }) {
      activeManager = nil
      finish(command, .success(response(for: managers.first)))
      return
    }

    DispatchQueue.main.asyncAfter(
      deadline: .now() + Constants.connectionPollInterval
    ) {
      self.waitUntilAllStopped(managers, command: command)
    }
  }

  // MARK: - Owned profile maintenance

  private func disableAndRemoveDuplicates(
    _ managers: [NETunnelProviderManager],
    index: Int,
    command: Command,
    completion: @escaping () -> Void
  ) {
    guard isCurrent(command) else { return }
    guard index < managers.count else {
      completion()
      return
    }

    let manager = managers[index]
    if Self.needsStopRequest(manager.connection.status) {
      manager.connection.stopVPNTunnel()
    }

    waitUntilQuiescent(manager, command: command, settle: false) {
      manager.isOnDemandEnabled = false
      manager.onDemandRules = []
      manager.isEnabled = false

      manager.saveToPreferences { error in
        DispatchQueue.main.async {
          guard self.isCurrent(command) else { return }
          if let error {
            self.finish(command, .failure(Self.configurationFailure(error)))
            return
          }

          manager.removeFromPreferences { error in
            DispatchQueue.main.async {
              guard self.isCurrent(command) else { return }
              if let error {
                self.finish(command, .failure(Self.configurationFailure(error)))
                return
              }
              self.disableAndRemoveDuplicates(
                managers,
                index: index + 1,
                command: command,
                completion: completion
              )
            }
          }
        }
      }
    }
  }

  private func configure(
    _ manager: NETunnelProviderManager,
    providerIdentifier: String,
    installationToken: String
  ) {
    let tunnelProtocol =
      manager.protocolConfiguration as? NETunnelProviderProtocol ??
      NETunnelProviderProtocol()

    tunnelProtocol.providerBundleIdentifier = providerIdentifier
    tunnelProtocol.serverAddress = Constants.serverAddress
    tunnelProtocol.providerConfiguration = [
      Constants.schemaVersionKey: Constants.schemaVersion,
      Constants.interfaceAddressKey: Constants.interfaceAddress,
      Constants.peerAddressKey: Constants.peerAddress,
      Constants.installationTokenKey: installationToken,
    ]

    manager.protocolConfiguration = tunnelProtocol
    manager.localizedDescription = Constants.localizedDescription
    manager.isOnDemandEnabled = false
    manager.onDemandRules = []
    manager.isEnabled = true
  }

  // MARK: - Command lifecycle

  private func beginCommand(
    intent: String,
    timeout: TimeInterval,
    completion: @escaping (Response) -> Void
  ) -> Command {
    dispatchPrecondition(condition: .onQueue(.main))

    if let previous = command {
      finish(previous, .failure(.cancelled))
    }

    serial &+= 1
    let command = Command(
      id: serial,
      intent: intent,
      completion: completion
    )
    self.command = command

    let work = DispatchWorkItem { [weak self, weak command] in
      guard let self, let command, self.isCurrent(command) else { return }
      self.finish(
        command,
        .failure(.timeout(
          "intent=\(intent); limit=\(Int(timeout))s"
        ))
      )
    }
    command.timeout = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + timeout,
      execute: work
    )
    return command
  }

  private func isCurrent(_ command: Command) -> Bool {
    self.command === command && !command.completed
  }

  private func finish(_ command: Command, _ response: Response) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard isCurrent(command) else { return }

    command.completed = true
    command.timeout?.cancel()
    command.timeout = nil
    self.command = nil

    if case .failure(let error) = response {
      lastFailure = error
    } else {
      lastFailure = nil
    }

    let waiters = command.waiters
    command.waiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter(response) }
  }

  // MARK: - Route probe

  private func probeJitRoute(completion: @escaping (Bool) -> Void) {
    let queue = DispatchQueue(
      label: "com.neogamelab.neostation.localtunnel.route-probe",
      qos: .userInitiated
    )
    let connection = NWConnection(
      host: NWEndpoint.Host(Constants.peerAddress),
      port: NWEndpoint.Port(rawValue: Constants.jitPort)!,
      using: .tcp
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
      case .ready:
        finish(true)
      case .failed, .cancelled:
        finish(false)
      default:
        break
      }
    }

    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + Constants.routeProbeTimeout) {
      finish(false)
    }
  }

  // MARK: - State helpers

  private func routeResponse(
    for manager: NETunnelProviderManager?
  ) -> [String: Any] {
    if let manager, Self.isActive(manager.connection.status) {
      return response(for: manager, routeVerified: true)
    }

    return [
      "active": true,
      "status": "reachableRoute",
      "managedByNeoStation": false,
      "configured": false,
      "authorized": false,
      "enabled": true,
      "interfaceAddress": NSNull(),
      "peerAddress": Constants.peerAddress,
      "onDemand": false,
      "routeVerified": true,
      "lastErrorCode": NSNull(),
      "lastErrorDetail": NSNull(),
    ]
  }

  private func response(
    for manager: NETunnelProviderManager?,
    routeVerified: Bool = false
  ) -> [String: Any] {
    let status = manager?.connection.status ?? .invalid

    return [
      "active": Self.isActive(status),
      "status": Self.statusName(status),
      "managedByNeoStation": true,
      "configured": manager != nil,
      "authorized": manager != nil,
      "enabled": manager?.isEnabled ?? false,
      "interfaceAddress": Constants.interfaceAddress,
      "peerAddress": Constants.peerAddress,
      "onDemand": manager?.isOnDemandEnabled ?? false,
      "routeVerified": routeVerified,
      "lastErrorCode":
        lastFailure.map { "local_tunnel_" + $0.code } as Any? ?? NSNull(),
      "lastErrorDetail":
        lastFailure?.localizedDescription as Any? ?? NSNull(),
    ]
  }

  private func installationToken() -> String {
    let defaults = UserDefaults.standard
    if let existing = defaults.string(
      forKey: Constants.installationTokenDefaultsKey
    ), !existing.isEmpty {
      return existing
    }

    let token = UUID().uuidString
    defaults.set(token, forKey: Constants.installationTokenDefaultsKey)
    return token
  }

  private static func installationToken(
    for manager: NETunnelProviderManager
  ) -> String? {
    (manager.protocolConfiguration as? NETunnelProviderProtocol)?
      .providerConfiguration?[Constants.installationTokenKey] as? String
  }

  private func providerBundleIdentifier() -> String? {
    guard
      let bundle = Self.installedExtensionBundle(),
      let identifier = bundle.bundleIdentifier,
      !identifier.isEmpty
    else {
      return nil
    }
    return identifier
  }

  private static func preferredManager(
    in managers: [NETunnelProviderManager],
    providerBundleIdentifier: String?
  ) -> NETunnelProviderManager? {
    managers.first(where: {
      providerBundleIdentifier != nil &&
        providerIdentifier(for: $0) == providerBundleIdentifier &&
        isActive($0.connection.status)
    }) ??
    managers.first(where: { isActive($0.connection.status) }) ??
    managers.first(where: {
      providerBundleIdentifier != nil &&
        providerIdentifier(for: $0) == providerBundleIdentifier
    }) ??
    managers.first
  }

  private static func isOwned(
    _ manager: NETunnelProviderManager,
    providerBundleIdentifier: String?
  ) -> Bool {
    if let providerBundleIdentifier,
       providerIdentifier(for: manager) == providerBundleIdentifier {
      return true
    }

    guard manager.localizedDescription == Constants.localizedDescription else {
      return false
    }

    let schema =
      (manager.protocolConfiguration as? NETunnelProviderProtocol)?
      .providerConfiguration?[Constants.schemaVersionKey] as? Int

    return schema == 1 ||
      schema == 2 ||
      schema == 3 ||
      schema == Constants.schemaVersion
  }

  private static func providerIdentifier(
    for manager: NETunnelProviderManager
  ) -> String? {
    (manager.protocolConfiguration as? NETunnelProviderProtocol)?
      .providerBundleIdentifier
  }

  private static func isActive(_ status: NEVPNStatus) -> Bool {
    status == .connected ||
      status == .connecting ||
      status == .reasserting
  }

  private static func needsHandoff(_ status: NEVPNStatus) -> Bool {
    isActive(status) || status == .disconnecting
  }

  private static func needsStopRequest(_ status: NEVPNStatus) -> Bool {
    status == .connected ||
      status == .connecting ||
      status == .reasserting
  }

  private static func isQuiescent(_ status: NEVPNStatus) -> Bool {
    status == .disconnected || status == .invalid
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

  private static func signingCapabilityFailure()
    -> NeoStationLocalTunnelError? {
    guard let extensionBundle = installedExtensionBundle() else {
      return .extensionMissing
    }

    for bundle in [Bundle.main, extensionBundle] {
      if let values = provisioningEntitlements(in: bundle),
         !entitlement(
          values,
          key: "com.apple.developer.networking.networkextension",
          contains: "packet-tunnel-provider"
         ) {
        return .signingMissing
      }
    }

    return nil
  }

  private static func entitlement(
    _ entitlements: [String: Any],
    key: String,
    contains value: String
  ) -> Bool {
    if let values = entitlements[key] as? [String] {
      return values.contains(value)
    }
    return (entitlements[key] as? String) == value
  }

  private static func provisioningEntitlements(
    in bundle: Bundle
  ) -> [String: Any]? {
    guard
      let url = bundle.url(
        forResource: "embedded",
        withExtension: "mobileprovision"
      ),
      let data = try? Data(contentsOf: url),
      let start = data.range(of: Data("<?xml".utf8)),
      let end = data.range(
        of: Data("</plist>".utf8),
        options: [],
        in: start.lowerBound..<data.endIndex
      )
    else {
      return nil
    }

    guard let root = try? PropertyListSerialization.propertyList(
      from: Data(data[start.lowerBound..<end.upperBound]),
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

  private static func configurationFailure(
    _ error: Error
  ) -> NeoStationLocalTunnelError {
    let nsError = error as NSError
    if nsError.domain == NEVPNErrorDomain,
       nsError.code ==
        NEVPNError.configurationReadWriteFailed.rawValue {
      return .permissionDenied
    }
    return .configuration(errorDetail(error))
  }

  private static func errorDetail(_ error: Error) -> String {
    let nsError = error as NSError
    var detail =
      "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
    if let underlying =
      nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
      detail +=
        "; underlying=\(underlying.domain)(\(underlying.code)): " +
        underlying.localizedDescription
    }
    return detail
  }
}

@available(iOS 17.4, *)
enum NeoStationLocalTunnelError: LocalizedError {
  case extensionMissing
  case signingMissing
  case routeUnavailable
  case permissionDenied
  case cancelled
  case configuration(String)
  case start(String)
  case stop(String)
  case timeout(String)

  var code: String {
    switch self {
    case .extensionMissing: return "extension_missing"
    case .signingMissing: return "signing_missing"
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
      return
        "The NeoStation local tunnel extension is missing from this installation. " +
        "Re-sign the complete IPA with app extensions enabled."
    case .signingMissing:
      return
        "The installed NeoStation signature does not include Apple's packet-tunnel " +
        "entitlement. Re-sign the complete NeoStation IPA with the Network Extension " +
        "entitlement enabled."
    case .routeUnavailable:
      return
        "The JIT transport at 10.7.0.1:49152 is not reachable. " +
        "The VPN state was not changed."
    case .configuration(let message):
      return
        "iOS could not save the NeoStation local tunnel. Technical detail: \(message)"
    case .start(let message):
      return
        "The NeoStation local JIT tunnel could not start: \(message)"
    case .stop(let message):
      return
        "The NeoStation local JIT tunnel could not stop: \(message)"
    case .permissionDenied:
      return
        "iOS refused the NeoStation VPN configuration. Verify the signed Network " +
        "Extension entitlement and authorize the VPN when iOS asks."
    case .timeout(let message):
      return
        "The NeoStation VPN command did not finish before its timeout. " +
        "The tunnel was not stopped automatically. \(message)"
    case .cancelled:
      return
        "The previous NeoStation VPN command was superseded by a newer explicit " +
        "Settings command."
    }
  }
}
