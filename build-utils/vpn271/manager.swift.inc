import Foundation
import Network
import NetworkExtension

/// NEOSTATION_VPN_CONTROL_271. VPN commands are finite, single-completion
/// transactions. No command or preference callback may change JIT state.
@available(iOS 17.4, *)
final class NeoStationLocalTunnelManager {
  static let shared = NeoStationLocalTunnelManager()
  private enum Constants {
    static let schemaVersion = 3
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
  }
  typealias Response = Result<[String: Any], NeoStationLocalTunnelError>
  private final class Request {
    let id: UInt64
    let intent: String
    let started = ProcessInfo.processInfo.systemUptime
    var step = "begin"
    var complete = false
    var waiters: [(Response) -> Void]
    var deadline: DispatchWorkItem?
    var touched: [NETunnelProviderManager] = []
    init(_ id: UInt64, _ intent: String, _ completion: @escaping (Response) -> Void) {
      self.id = id; self.intent = intent; waiters = [completion]
    }
  }
  private var serial: UInt64 = 0
  private var current: Request?
  private var activeManager: NETunnelProviderManager?
  private var lastFailure: NeoStationLocalTunnelError?
  private var trace = [String]()
  private init() {}

  func ensureRunning(completion: @escaping (Response) -> Void) {
    route(owned: false, completion: completion)
  }
  func enableOwned(completion: @escaping (Response) -> Void) {
    route(owned: true, completion: completion)
  }
  private func route(owned: Bool, completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      let intent = owned ? "activate-owned" : "ensure-route"
      if let previous = self.current {
        if previous.intent == intent || (!owned && previous.intent == "activate-owned") {
          previous.waiters.append(completion); return
        }
        if !owned && previous.intent == "stop-owned" {
          completion(.failure(.cancelled)); return
        }
      }
      let request = self.begin(intent, seconds: 30, completion: completion)
      if let manager = self.activeManager, manager.connection.status == .connected {
        // Verify the existing session without saving, stopping, or reopening it.
        self.verify(manager, request); return
      }
      if owned { self.loadForStart(request); return }
      self.mark(request, "existing-route-probe")
      self.probeJitRoute { ready in
        guard self.valid(request) else { return }
        if ready {
          // Reachability is NOT an identification of a third-party VPN. Leave
          // the existing route alone and never require our extension signing.
          self.finish(request, .success(self.externalRouteResponse()))
        } else { self.loadForStart(request) }
      }
    }
  }

  func status(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      // NEOSTATION_VPN_PERSISTENCE_275: a live connection object is the
      // authoritative state. Do not replace it with a stale saved duplicate.
      if let cached = self.activeManager, Self.isActive(cached.connection.status) {
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

  func disable(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      // Cancel and settle an activation immediately, even when iOS has not
      // returned its save/load callback. No dependency on activation's end.
      let request = self.begin("stop-owned", seconds: 10, completion: completion)
      self.activeManager?.connection.stopVPNTunnel()
      self.awaitValue(request, "stop.load-preferences", seconds: 4, start: { done in
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
          if let error { done(.failure(error)) } else { done(.success(managers ?? [])) }
        }
      }) { (managers: [NETunnelProviderManager]) in
        let owned = managers.filter { Self.isOwned($0, providerBundleIdentifier: self.providerBundleIdentifier()) }
        for manager in owned { manager.connection.stopVPNTunnel() }
        self.stopNext(owned, index: 0, request: request)
      }
    }
  }

  private func begin(_ intent: String, seconds: TimeInterval,
                     completion: @escaping (Response) -> Void) -> Request {
    dispatchPrecondition(condition: .onQueue(.main))
    if let previous = current {
      for manager in previous.touched { manager.connection.stopVPNTunnel() }
      finish(previous, .failure(.cancelled))
    }
    serial &+= 1
    let request = Request(serial, intent, completion)
    current = request; trace = []; lastFailure = nil
    mark(request, "begin")
    NeoStationVPNDiagnostics.snapshotRPCS3()
    let deadline = DispatchWorkItem { [weak self, weak request] in
      guard let self, let request, self.valid(request) else { return }
      self.fail(request, .timeout("build=271; overall=\(seconds)s; stage=\(request.step)"))
    }
    request.deadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: deadline)
    return request
  }
  private func valid(_ request: Request) -> Bool { current === request && !request.complete }
  private func mark(_ request: Request, _ step: String) {
    request.step = step
    let line = "op=\(request.id); intent=\(request.intent); step=\(step); elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime-request.started))s"
    trace.append(line); if trace.count > 40 { trace.removeFirst() }
    NeoStationVPNDiagnostics.record("vpn", line)
  }
  private func finish(_ request: Request, _ result: Response) {
    guard valid(request) else { return }
    mark(request, "end: " + summary(result))
    request.complete = true; request.deadline?.cancel(); request.deadline = nil
    current = nil
    if case .failure(let error) = result { lastFailure = error } else { lastFailure = nil }
    let waiters = request.waiters; request.waiters = []
    NeoStationVPNDiagnostics.snapshotRPCS3()
    for waiter in waiters { waiter(result) }
  }
  private func fail(_ request: Request, _ error: NeoStationLocalTunnelError) {
    guard valid(request) else { return }
    for manager in request.touched { manager.connection.stopVPNTunnel() }
    // Never await another preferences call on an error path.
    finish(request, .failure(error))
  }
  private func summary(_ result: Response) -> String {
    switch result {
    case .success(let state): return "success; state=\(state["status"] ?? "unknown"); owned=\(state["managedByNeoStation"] ?? false); verified=\(state["routeVerified"] ?? false)"
    case .failure(let error): return "error=\(error.code); \(error.localizedDescription)"
    }
  }
  /// Every Apple callback is single-shot, bounded, and operation-scoped. A
  /// late callback may report completion but cannot run its continuation.
  private func awaitValue<T>(_ request: Request, _ step: String, seconds: TimeInterval = 5,
      start: (@escaping (Result<T, Error>) -> Void) -> Void,
      next: @escaping (T) -> Void) {
    guard valid(request) else { return }
    mark(request, step)
    var settled = false
    let finish: (Result<T, Error>) -> Void = { result in
      DispatchQueue.main.async {
        guard !settled else { return }; settled = true
        guard self.valid(request) else {
          NeoStationVPNDiagnostics.record("ignored", "late callback; op=\(request.id); step=\(step)"); return
        }
        switch result {
        case .success(let value): next(value)
        case .failure(let error): self.fail(request, Self.configurationFailure(error))
        }
      }
    }
    start(finish)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
      guard !settled else { return }; settled = true
      guard self.valid(request) else { return }
      self.fail(request, .timeout("build=271; stage=\(step); limit=\(seconds)s; no native callback"))
    }
  }

  private func loadForStart(_ request: Request) {
    guard valid(request) else { return }
    guard let identifier = providerBundleIdentifier() else { fail(request, .extensionMissing); return }
    if let error = Self.signingCapabilityFailure() { fail(request, error); return }
    awaitValue(request, "start.load-preferences", start: { done in
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        if let error { done(.failure(error)) } else { done(.success(managers ?? [])) }
      }
    }) { (managers: [NETunnelProviderManager]) in
      let owned = managers.filter { Self.isOwned($0, providerBundleIdentifier: identifier) }
      // Prefer the live/current profile. A disabled duplicate left by an older
      // signed build must never win selection and force a needless restart.
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
      // Existing duplicate profiles are not deleted. Prevent only *owned*
      // active duplicates from competing with this session.
      for manager in owned where manager !== selected { manager.connection.stopVPNTunnel() }
      if selected.connection.status == .connected { self.verify(selected, request); return }
      request.touched.append(selected)
      selected.connection.stopVPNTunnel()
      self.waitStopped([selected], request, deadline: ProcessInfo.processInfo.systemUptime + 5) {
        self.configure(selected, identifier)
        self.awaitValue(request, "start.save-preferences", seconds: 12, start: { done in
          selected.saveToPreferences { error in
            if let error { done(.failure(error)) } else { done(.success(())) }
          }
        }) { (_: Void) in
          self.awaitValue(request, "start.reload-preferences", start: { done in
            selected.loadFromPreferences { error in
              if let error { done(.failure(error)) } else { done(.success(())) }
            }
          }) { (_: Void) in self.start(selected, request) }
        }
      }
    }
  }
  private func configure(_ manager: NETunnelProviderManager, _ identifier: String) {
    let protocolConfiguration = NETunnelProviderProtocol()
    protocolConfiguration.providerBundleIdentifier = identifier
    protocolConfiguration.serverAddress = Constants.serverAddress
    protocolConfiguration.providerConfiguration = [
      Constants.schemaVersionKey: Constants.schemaVersion,
      Constants.interfaceAddressKey: Constants.interfaceAddress,
      Constants.peerAddressKey: Constants.peerAddress,
    ]
    manager.protocolConfiguration = protocolConfiguration
    manager.localizedDescription = Constants.localizedDescription
    manager.onDemandRules = []; manager.isOnDemandEnabled = false; manager.isEnabled = true
  }
  private func start(_ manager: NETunnelProviderManager, _ request: Request) {
    guard valid(request) else { return }
    mark(request, "start.system-request")
    do {
      try manager.connection.startVPNTunnel(options: [
        Constants.interfaceAddressKey: Constants.interfaceAddress as NSString,
        Constants.peerAddressKey: Constants.peerAddress as NSString,
      ])
    } catch { fail(request, .start(Self.errorDetail(error))); return }
    waitConnected(manager, request, deadline: ProcessInfo.processInfo.systemUptime + 12, observed: false)
  }
  private func waitConnected(_ manager: NETunnelProviderManager, _ request: Request,
                             deadline: TimeInterval, observed: Bool) {
    guard valid(request) else { return }
    let status = manager.connection.status
    let step = "start.wait-connected." + Self.statusName(status)
    if request.step != step { mark(request, step) }
    if status == .connected { verify(manager, request); return }
    if status == .invalid || (status == .disconnected && observed) || ProcessInfo.processInfo.systemUptime >= deadline {
      var settled = false
      let end: (Error?) -> Void = { error in
        guard !settled else { return }; settled = true
        guard self.valid(request) else { return }
        self.fail(request, .start("build=271; stage=\(step); " + (error.map(Self.errorDetail) ?? "iOS supplied no disconnect error")))
      }
      manager.connection.fetchLastDisconnectError { error in DispatchQueue.main.async { end(error) } }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { end(nil) }
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      self.waitConnected(manager, request, deadline: deadline,
                         observed: observed || status == .connecting || status == .reasserting)
    }
  }
  private func verify(_ manager: NETunnelProviderManager, _ request: Request) {
    guard valid(request) else { return }
    guard let session = manager.connection as? NETunnelProviderSession else { fail(request, .routeUnavailable); return }
    if !request.touched.contains(where: { $0 === manager }) { request.touched.append(manager) }
    mark(request, "verify.provider")
    var settled = false
    let end: (Data?) -> Void = { data in
      guard !settled else { return }; settled = true
      guard self.valid(request) else { return }
      guard session.status == .connected, let data,
            let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            values["version"] as? Int == 271, values["ready"] as? Bool == true else {
        self.fail(request, .start("build=271; stage=verify.provider; extension did not confirm version/ready")); return
      }
      // Only non-sensitive aggregate transport statistics are exported.
      for key in ["readPackets", "writtenPackets", "droppedPackets", "writeFailures", "uptime"] {
        if let value = values[key] as? NSNumber { NeoStationVPNDiagnostics.record("provider", "\(key)=\(value)") }
      }
      self.mark(request, "verify.remote-pairing-tcp")
      self.probeJitRoute { ready in
        guard self.valid(request) else { return }
        guard ready, session.status == .connected else { self.fail(request, .routeUnavailable); return }
        self.activeManager = manager
        self.finish(request, .success(self.response(for: manager, routeVerified: true)))
      }
    }
    do {
      try session.sendProviderMessage(Data("vpn271-status".utf8)) { data in DispatchQueue.main.async { end(data) } }
    } catch { end(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { end(nil) }
  }
  private func stopNext(_ managers: [NETunnelProviderManager], index: Int, request: Request) {
    guard valid(request) else { return }
    guard index < managers.count else {
      waitStopped(managers, request, deadline: ProcessInfo.processInfo.systemUptime + 5) {
        self.activeManager = nil
        self.finish(request, .success(self.response(for: managers.first)))
      }; return
    }
    let manager = managers[index]
    manager.isOnDemandEnabled = false; manager.onDemandRules = []; manager.isEnabled = false
    awaitValue(request, "stop.save-preferences.\(index)", start: { done in
      manager.saveToPreferences { error in
        if let error { done(.failure(error)) } else { done(.success(())) }
      }
    }) { (_: Void) in
      manager.connection.stopVPNTunnel()
      self.stopNext(managers, index: index + 1, request: request)
    }
  }
  private func waitStopped(_ managers: [NETunnelProviderManager], _ request: Request,
                           deadline: TimeInterval, next: @escaping () -> Void) {
    guard valid(request) else { return }
    if managers.allSatisfy({ $0.connection.status == .disconnected || $0.connection.status == .invalid }) { next(); return }
    if request.step != "wait-disconnected" { mark(request, "wait-disconnected") }
    guard ProcessInfo.processInfo.systemUptime < deadline else {
      fail(request, .stop("build=271; stage=wait-disconnected; limit=5s")); return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.waitStopped(managers, request, deadline: deadline, next: next) }
  }
  private func probeJitRoute(completion: @escaping (Bool) -> Void) {
    let queue = DispatchQueue(label: "neostation.vpn271.probe", qos: .userInitiated)
    let connection = NWConnection(host: NWEndpoint.Host(Constants.peerAddress),
                                  port: NWEndpoint.Port(rawValue: Constants.jitPort)!, using: .tcp)
    var finished = false
    let finish: (Bool) -> Void = { success in
      guard !finished else { return }; finished = true
      connection.stateUpdateHandler = nil; connection.cancel()
      DispatchQueue.main.async { completion(success) }
    }
    connection.stateUpdateHandler = { state in
      switch state { case .ready: finish(true); case .failed, .cancelled: finish(false); default: break }
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + Constants.routeProbeTimeout) { finish(false) }
  }
