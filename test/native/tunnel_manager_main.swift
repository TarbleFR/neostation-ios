import Foundation

@main struct TunnelManagerTests {
  static func main() {
    let manager = NeoStationLocalTunnelManager.shared
    let scenario = CommandLine.arguments[1]
    var finished = false
    var results = [NeoStationLocalTunnelManager.Response]()
    var seededProfile: NETunnelProviderManager?
    func done(_ result: NeoStationLocalTunnelManager.Response) { results.append(result); finished = true }
    func demand(_ value: @autoclosure () -> Bool, _ detail: String) {
      if !value() { fatalError("\(scenario): \(detail); events=\(TunnelTestState.events)") }
    }
    switch scenario {
    case "on-off-late-save":
      TunnelTestState.saveDelay = 0.06
      manager.enableOwned { results.append($0) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { manager.disable(completion: done) }
    case "timeout-retry":
      TunnelTestState.startMode = "stuck"
      manager.enableOwned { result in
        results.append(result)
        demand(!TunnelTestState.profiles.isEmpty, "profile retained")
        demand(TunnelTestState.profiles[0].connection.status == .disconnected, "unfinished start rolled back")
        TunnelTestState.startMode = "success"
        manager.enableOwned(completion: done)
      }
    case "fail-fast":
      TunnelTestState.startMode = "fail-fast"
      manager.enableOwned(completion: done)
    case "stale-plugin-rebuild":
      let profile = NETunnelProviderManager()
      let proto = NETunnelProviderProtocol(); proto.providerBundleIdentifier = "test.neostation.localtunnel"
      profile.protocolConfiguration = proto; profile.isEnabled = true
      profile.connection.startError = NSError(
        domain: NEVPNConnectionErrorDomain,
        code: NEVPNConnectionError.pluginFailed.rawValue
      )
      seededProfile = profile
      TunnelTestState.profiles = [profile]
      manager.enableOwned(completion: done)
    case "plugin-rebuild-once":
      let profile = NETunnelProviderManager()
      let proto = NETunnelProviderProtocol(); proto.providerBundleIdentifier = "test.neostation.localtunnel"
      profile.protocolConfiguration = proto; profile.isEnabled = true
      TunnelTestState.profiles = [profile]
      TunnelTestState.startMode = "always-plugin-fail"
      manager.enableOwned(completion: done)
    case "duplicate-on":
      manager.enableOwned { results.append($0) }
      manager.enableOwned(completion: done)
    case "connected-no-save":
      let profile = NETunnelProviderManager()
      let proto = NETunnelProviderProtocol(); proto.providerBundleIdentifier = "test.neostation.localtunnel"
      profile.protocolConfiguration = proto; profile.isEnabled = true; profile.connection.status = .connected
      TunnelTestState.profiles = [profile]
      manager.enableOwned(completion: done)
    case "readonly-route":
      manager.ensureRunning { result in
        results.append(result)
        TunnelTestState.routeReachable = true
        manager.ensureRunning(completion: done)
      }
    default: fatalError("unknown test")
    }
    let deadline = Date().addingTimeInterval(2)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    demand(finished, "completion must be bounded")
    switch scenario {
    case "on-off-late-save":
      demand(results.count == 2, "each callback exactly once")
      demand(!TunnelTestState.events.contains("start"), "cancelled ON never starts")
      demand(TunnelTestState.events.firstIndex(of: "save-end-true")! < TunnelTestState.events.firstIndex(of: "save-begin-false")!, "OFF must wait for ON write")
      demand(TunnelTestState.profiles.first?.isEnabled == false, "latest intent wins")
    case "timeout-retry":
      demand(results.count == 2, "both attempts complete")
      if case .success = results[0] { fatalError("timeout cannot succeed") }
      if case .failure = results[1] { fatalError("retry must recover") }
      demand(TunnelTestState.events.filter { $0 == "stop" }.count == 1, "only unfinished start stopped")
    case "fail-fast":
      if case .failure(let error) = results[0] { demand(error.localizedDescription.contains("ProviderFailure"), "native cause preserved") }
      else { fatalError("failed provider cannot succeed") }
    case "stale-plugin-rebuild":
      if case .failure = results[0] { fatalError("stale plugin profile must recover") }
      demand(TunnelTestState.events.filter { $0 == "start" }.count == 2, "recreated profile starts once")
      demand(TunnelTestState.events.filter { $0 == "remove" }.count == 1, "failed owned profile removed once")
      demand(seededProfile != nil && TunnelTestState.profiles.count == 1 && TunnelTestState.profiles[0] !== seededProfile!, "replacement profile persisted")
    case "plugin-rebuild-once":
      if case .success = results[0] { fatalError("persistent plugin failure cannot succeed") }
      demand(TunnelTestState.events.filter { $0 == "start" }.count == 2, "only one rebuild retry")
      demand(TunnelTestState.events.filter { $0 == "remove" }.count == 1, "only one profile rebuild")
    case "duplicate-on": demand(TunnelTestState.events.filter { $0 == "start" }.count == 1 && results.count == 2, "coalesce duplicate ON")
    case "connected-no-save": demand(TunnelTestState.events == ["load"], "do not rewrite connected profile")
    case "readonly-route": demand(!TunnelTestState.events.contains(where: { $0 == "start" || $0 == "stop" || $0.hasPrefix("save") }), "route preflight is read-only")
    default: break
    }
    print("PASS \(scenario)")
  }
}
