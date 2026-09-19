import Foundation
#if !NEOSTATION_TUNNEL_TESTING
import Network
import NetworkExtension
#endif

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
    static let interfaceAddress = "10.7.1.1"
    static let peerAddress = "10.7.0.1"
    static let jitPort: UInt16 = 49152
    static let extensionName = "NeoStationLocalTunnel.appex"
    static let localizedDescription = "NeoStation Local JIT Tunnel"
    static let serverAddress = "10.7.0.1"
    static let routeProbeTimeout: TimeInterval = 1.25
#if NEOSTATION_TUNNEL_TESTING
    static let connectionPollInterval: TimeInterval = 0.005
    static let handoffSettleDelay: TimeInterval = 0.005
    static let activationTimeout: TimeInterval = 0.15
    static let stopTimeout: TimeInterval = 0.10
#else
    static let connectionPollInterval: TimeInterval = 0.20
    static let handoffSettleDelay: TimeInterval = 1.0
    static let activationTimeout: TimeInterval = 45
    static let stopTimeout: TimeInterval = 12
#endif
  }

  typealias Response = Result<[String: Any], NeoStationLocalTunnelError>

  private final class Command {
    let id: UInt64
    let intent: String
    var completed = false
    var phase = "created"
    var manager: NETunnelProviderManager?
    var startedTunnel = false
    var recovering = false
    var observedConnecting = false
    var observer: NSObjectProtocol?
    let startedAt = ProcessInfo.processInfo.systemUptime
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
  private var preferenceWrites = 0
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
          if self.command == nil { self.activeManager = manager }
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
      self.afterPreferenceWrites(command) { self.loadAndEnable(command) }
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

    trace(command, "load_profiles")
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

        // Keep NeoStation's own VPN profile stable across sideload updates and
        // reinstalls. Build 279 proved that reusing the existing profile is the
        // reliable path; do not delete/recreate it just because the app
        // container changed.
        //
        // LocalDevVPN can remain On-Demand even after its UI says "stopped".
        // Treat a matching local-JIT profile as a handoff contender when it is
        // active OR still has On-Demand enabled. Neutralize its On-Demand rules,
        // persist that change, then stop and wait for a real disconnected state
        // before starting NeoStation.
        let foreignContenders = allManagers.filter {
          !Self.isOwned($0, providerBundleIdentifier: providerIdentifier) &&
            Self.isLocalJitForeignManager($0) &&
            (Self.needsHandoff($0.connection.status) || $0.isOnDemandEnabled)
        }
        if !foreignContenders.isEmpty {
          self.neutralizeForeignManagersForHandoff(
            foreignContenders,
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

        let manager = Self.preferredManager(
          in: owned,
          providerBundleIdentifier: providerIdentifier
        ) ?? NETunnelProviderManager()
        self.activeManager = manager
        command.manager = manager

        let duplicates = owned.filter { $0 !== manager }
        self.disableAndRemoveDuplicates(
          duplicates,
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
              command: command
            )
          }
        }
      }
    }
  }

  private func neutralizeForeignManagersForHandoff(
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

    // LocalDevVPN persists connectIfNeeded rules. stopVPNTunnel() alone does not
    // make that profile inert, so remove On-Demand first and persist it before
    // asking iOS to stop the connection.
    manager.isOnDemandEnabled = false
    manager.onDemandRules = []

    save(manager, command: command) { error in
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

            if Self.needsStopRequest(manager.connection.status) {
              manager.connection.stopVPNTunnel()
            }

            self.waitUntilQuiescent(
              manager,
              command: command,
              settle: false
            ) {
              self.neutralizeForeignManagersForHandoff(
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
    command: Command
  ) {
    guard isCurrent(command) else { return }

    if manager.connection.status == .connected &&
       Self.providerIdentifier(for: manager) == providerIdentifier &&
       manager.isEnabled && !manager.isOnDemandEnabled {
      finish(command, .success(response(for: manager)))
      return
    }
    trace(command, "save_owned_profile")
    configure(
      manager,
      providerIdentifier: providerIdentifier
    )
    save(manager, command: command) { error in
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

    trace(command, "start_requested")
    command.observer = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main
    ) { [weak self, weak command] _ in
      guard let self, let command, self.isCurrent(command) else { return }
      let status = manager.connection.status
      if status == .connecting || status == .reasserting {
        command.observedConnecting = true
      }
      self.trace(command, "status_" + Self.statusName(status))
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

    command.startedTunnel = true
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

    guard !command.recovering else { return }
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
    case .disconnected where observedConnecting || command.observedConnecting:
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
      self.afterPreferenceWrites(command) { self.loadAndDisable(command) }
    }
  }

  private func loadAndDisable(_ command: Command) {
    guard isCurrent(command) else { return }
    let identifier = providerBundleIdentifier()

    trace(command, "load_profiles")
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
        command.manager = owned.first
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

    save(manager, command: command) { error in
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

      self.save(manager, command: command) { error in
        DispatchQueue.main.async {
          guard self.isCurrent(command) else { return }
          if let error {
            self.finish(command, .failure(Self.configurationFailure(error)))
            return
          }

          self.writePreferences(command, phase: "remove_duplicate", operation: { manager.removeFromPreferences(completionHandler: $0) }) { error in
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
    providerIdentifier: String
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
      self.recoverTimedOutCommand(command, limit: timeout)
    }
    command.timeout = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + timeout,
      execute: work
    )
    return command
  }

  private func isCurrent(_ command: Command, allowRecovery: Bool = false) -> Bool {
    self.command === command && !command.completed && (allowRecovery || !command.recovering)
  }

  private func finish(_ command: Command, _ response: Response) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard isCurrent(command, allowRecovery: true) else { return }

    switch response {
    case .success: trace(command, "finished_success")
    case .failure(let error): trace(command, "finished_failure", detail: error.localizedDescription)
    }
    command.completed = true
    if let observer = command.observer {
      NotificationCenter.default.removeObserver(observer)
      command.observer = nil
    }
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

  // Writes cannot be cancelled by ignoring their callback: NetworkExtension
  // still commits them. Fence every save/remove before a newer Settings intent
  // loads a manager, including after timeout. A stale callback releases only
  // its fence and must never resume its superseded command.
  private func writePreferences(
    _ command: Command,
    phase: String,
    operation: (@escaping (Error?) -> Void) -> Void,
    completion: @escaping (Error?) -> Void
  ) {
    guard isCurrent(command) else { return }
    preferenceWrites += 1
    trace(command, phase)
    operation { error in
      DispatchQueue.main.async {
        self.preferenceWrites -= 1
        guard self.isCurrent(command) else { return }
        completion(error)
      }
    }
  }

  private func save(
    _ manager: NETunnelProviderManager,
    command: Command,
    completion: @escaping (Error?) -> Void
  ) {
    writePreferences(command, phase: "save_preferences", operation: {
      manager.saveToPreferences(completionHandler: $0)
    }, completion: completion)
  }

  private func afterPreferenceWrites(_ command: Command, _ action: @escaping () -> Void) {
    guard isCurrent(command) else { return }
    guard preferenceWrites == 0 else {
      trace(command, "waiting_previous_save")
      DispatchQueue.main.asyncAfter(deadline: .now() + Constants.connectionPollInterval) {
        self.afterPreferenceWrites(command, action)
      }
      return
    }
    action()
  }

  private func trace(_ command: Command, _ phase: String, detail: String = "") {
    guard command.phase != phase || !detail.isEmpty else { return }
    command.phase = phase
    let status = command.manager.map { Self.statusName($0.connection.status) } ?? "none"
    NeoStationVPNDiagnostics.record("vpn_command",
      "id=\(command.id); intent=\(command.intent); phase=\(phase); status=\(status); " +
      "elapsed=\(Int((ProcessInfo.processInfo.systemUptime - command.startedAt) * 1000))ms; " +
      "writes=\(preferenceWrites); \(detail)")
  }

  private func recoverTimedOutCommand(_ command: Command, limit: TimeInterval) {
    guard isCurrent(command), !command.recovering else { return }
    let failedPhase = command.phase
    command.recovering = true
    let manager = command.manager
    // Never tear down a connected VPN or an unrelated/foreign profile.
    // Only this explicit ON's unfinished start is eligible for rollback.
    if command.intent == "enable", command.startedTunnel,
       let manager, manager.connection.status == .connected {
      finish(command, .success(response(for: manager)))
      return
    }
    trace(command, "recovering_timeout", detail: "failedPhase=\(failedPhase)")
    let fallback = "intent=\(command.intent); phase=\(failedPhase); limit=\(Int(limit))s"
    var disconnectDetail = ""
    manager?.connection.fetchLastDisconnectError { error in
      DispatchQueue.main.async {
        guard self.isCurrent(command, allowRecovery: true) else { return }
        if let error { disconnectDetail = Self.errorDetail(error) }
      }
    }
    if command.intent == "enable", command.startedTunnel, let manager,
       manager.connection.status == .connecting || manager.connection.status == .reasserting {
      manager.connection.stopVPNTunnel()
    }
    let deadline = ProcessInfo.processInfo.systemUptime + Constants.stopTimeout
    func reconcile() {
      guard self.isCurrent(command, allowRecovery: true) else { return }
      let status = manager?.connection.status ?? .invalid
      if self.preferenceWrites == 0 && Self.isQuiescent(status) {
        self.activeManager = nil // next explicit ON must load fresh preferences
        self.finish(command, .failure(.timeout(fallback + "; recovered=quiescent; " + disconnectDetail)))
      } else if status == .connected && command.intent == "enable" {
        self.finish(command, .success(self.response(for: manager)))
      } else if ProcessInfo.processInfo.systemUptime >= deadline {
        self.activeManager = nil
        self.finish(command, .failure(.timeout(fallback + "; recoveryStatus=" + Self.statusName(status) + "; " + disconnectDetail)))
      } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.connectionPollInterval) { reconcile() }
      }
    }
    DispatchQueue.main.async { reconcile() }
  }

  // MARK: - Route probe

  private func probeJitRoute(completion: @escaping (Bool) -> Void) {
#if NEOSTATION_TUNNEL_TESTING
    completion(TunnelTestState.routeReachable)
#else
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
#endif
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
      "active": status == .connected,
      "commandPending": command != nil,
      "commandPhase": command?.phase as Any? ?? NSNull(),
      "commandId": command.map { $0.id } as Any? ?? NSNull(),
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
        (status == .connected ? nil : lastFailure).map { "local_tunnel_" + $0.code } as Any? ?? NSNull(),
      "lastErrorDetail":
        (status == .connected ? nil : lastFailure)?.localizedDescription as Any? ?? NSNull(),
    ]
  }

  private func providerBundleIdentifier() -> String? {
#if NEOSTATION_TUNNEL_TESTING
    return "test.neostation.localtunnel"
#else
    guard
      let bundle = Self.installedExtensionBundle(),
      let identifier = bundle.bundleIdentifier,
      !identifier.isEmpty
    else {
      return nil
    }
    return identifier
#endif
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

  private static func isLocalJitForeignManager(
    _ manager: NETunnelProviderManager
  ) -> Bool {
    guard
      let tunnelProtocol =
        manager.protocolConfiguration as? NETunnelProviderProtocol
    else {
      return false
    }

    if manager.localizedDescription == "LocalDevVPN" {
      return true
    }

    let configuration = tunnelProtocol.providerConfiguration ?? [:]
    let interface =
      configuration["TunnelIfaceIP"] as? String ?? ""
    let peer =
      configuration["TunnelPeerIP"] as? String ?? ""

    return interface.hasPrefix("10.7.1.1") ||
      peer.hasPrefix("10.7.0.1")
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
#if NEOSTATION_TUNNEL_TESTING
    return nil
#else
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
#endif
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
        "Recovery details: \(message)"
    case .cancelled:
      return
        "The previous NeoStation VPN command was superseded by a newer explicit " +
        "Settings command."
    }
  }
}
