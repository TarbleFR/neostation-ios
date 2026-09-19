import Foundation

// Only the OS adapter is replaced. Tests compile and exercise the production
// NeoStationLocalTunnelManager, including its callbacks, timers and writes.
enum NEVPNStatus { case invalid, disconnected, connecting, connected, reasserting, disconnecting }
let NEVPNErrorDomain = "NEVPNErrorDomain"
enum NEVPNError: Int { case configurationReadWriteFailed = 5 }
extension Notification.Name { static let NEVPNStatusDidChange = Notification.Name("NEVPNStatusDidChange") }
final class NETunnelProviderProtocol {
  var providerBundleIdentifier: String?
  var serverAddress: String?
  var providerConfiguration: [String: Any]?
}
enum TunnelTestState {
  static var profiles = [NETunnelProviderManager]()
  static var events = [String]()
  static var saveDelay: TimeInterval = 0
  static var startMode = "success"
  static var routeReachable = false
}
final class TestConnection: NSObject {
  var status: NEVPNStatus = .disconnected {
    didSet { NotificationCenter.default.post(name: .NEVPNStatusDidChange, object: self) }
  }
  var lastError: Error?
  func startVPNTunnel(options: [String: NSObject]?) throws {
    TunnelTestState.events.append("start")
    if TunnelTestState.startMode == "immediate-error" {
      throw NSError(domain: "StartFailure", code: 12)
    }
    status = .connecting
    if TunnelTestState.startMode == "success" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { self.status = .connected }
    } else if TunnelTestState.startMode == "fail-fast" {
      lastError = NSError(domain: "ProviderFailure", code: 42)
      status = .disconnected // deliberately shorter than the poll interval
    }
  }
  func stopVPNTunnel() {
    TunnelTestState.events.append("stop")
    status = .disconnecting
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { self.status = .disconnected }
  }
  func fetchLastDisconnectError(completionHandler: @escaping (Error?) -> Void) { completionHandler(lastError) }
}
final class NETunnelProviderManager {
  let connection = TestConnection()
  var protocolConfiguration: Any?
  var localizedDescription: String?
  var isEnabled = false
  var isOnDemandEnabled = false
  var onDemandRules: [Int]?
  static func loadAllFromPreferences(completionHandler: @escaping ([NETunnelProviderManager]?, Error?) -> Void) {
    TunnelTestState.events.append("load")
    DispatchQueue.main.async { completionHandler(TunnelTestState.profiles, nil) }
  }
  func saveToPreferences(completionHandler: @escaping (Error?) -> Void) {
    let enabled = isEnabled
    TunnelTestState.events.append("save-begin-\(enabled)")
    DispatchQueue.main.asyncAfter(deadline: .now() + TunnelTestState.saveDelay) {
      self.isEnabled = enabled
      if !TunnelTestState.profiles.contains(where: { $0 === self }) { TunnelTestState.profiles.append(self) }
      TunnelTestState.events.append("save-end-\(enabled)")
      completionHandler(nil)
    }
  }
  func loadFromPreferences(completionHandler: @escaping (Error?) -> Void) {
    DispatchQueue.main.async { completionHandler(nil) }
  }
  func removeFromPreferences(completionHandler: @escaping (Error?) -> Void) {
    TunnelTestState.profiles.removeAll { $0 === self }
    completionHandler(nil)
  }
}
enum NeoStationVPNDiagnostics {
  static func record(_ stage: String, _ detail: String) { print("\(stage): \(detail)") }
}
