import Foundation
import Network

/// A bounded, read-only proof that LocalDevVPN exposes RemotePairing/RSD.
///
/// This probe uses the Network framework only. NeoStation does not inspect,
/// save, start, stop, or otherwise mutate VPN profiles.
final class LocalDevVpnRouteProbe {
  static let host = "10.7.0.1"
  static let port: UInt16 = 49152
  static let timeout: TimeInterval = 1.25

  private let queue = DispatchQueue(
    label: "com.neogamelab.neostation.localdevvpn-route-probe",
    qos: .userInitiated
  )
  private let startedAt = DispatchTime.now().uptimeNanoseconds
  private var connection: NWConnection?
  private var completion: (([String: Any]) -> Void)?
  private var finished = false
  private var lastNetworkState = "setup"
  private var lastError: NWError?

  static func probe(completion: @escaping ([String: Any]) -> Void) {
    LocalDevVpnRouteProbe().start(completion: completion)
  }

  private func start(completion: @escaping ([String: Any]) -> Void) {
    self.completion = completion

    guard let endpointPort = NWEndpoint.Port(rawValue: Self.port) else {
      finish(
        reachable: false,
        state: "invalidEndpoint",
        errorDescription: "LocalDevVPN endpoint port \(Self.port) is invalid."
      )
      return
    }

    let connection = NWConnection(
      host: NWEndpoint.Host(Self.host),
      port: endpointPort,
      using: .tcp
    )
    self.connection = connection
    connection.stateUpdateHandler = { [self] state in
      switch state {
      case .setup:
        lastNetworkState = "setup"
      case .preparing:
        lastNetworkState = "preparing"
      case .waiting(let error):
        lastNetworkState = "waiting"
        lastError = error
      case .ready:
        lastNetworkState = "ready"
        finish(reachable: true, state: "ready")
      case .failed(let error):
        lastNetworkState = "failed"
        lastError = error
        finish(reachable: false, state: "failed", error: error)
      case .cancelled:
        lastNetworkState = "cancelled"
        finish(
          reachable: false,
          state: "cancelled",
          errorDescription: "LocalDevVPN route probe was cancelled."
        )
      @unknown default:
        lastNetworkState = "unknown"
      }
    }
    connection.start(queue: queue)

    queue.asyncAfter(deadline: .now() + Self.timeout) { [self] in
      finish(
        reachable: false,
        state: "timeout",
        error: lastError,
        errorDescription: "Timed out waiting for LocalDevVPN at \(Self.host):\(Self.port)."
      )
    }
  }

  private func finish(
    reachable: Bool,
    state: String,
    error: NWError? = nil,
    errorDescription: String? = nil
  ) {
    guard !finished else { return }
    finished = true

    let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAt
    var response: [String: Any] = [
      "reachable": reachable,
      "host": Self.host,
      "port": Int(Self.port),
      "elapsedMs": Int(elapsedNanoseconds / 1_000_000),
      "state": state,
      "networkState": lastNetworkState,
    ]

    if let error {
      let nativeError = error as NSError
      response["errorDomain"] = nativeError.domain
      response["errorCode"] = String(nativeError.code)
      response["errorDescription"] = nativeError.localizedDescription
    } else if let errorDescription {
      response["errorCode"] = state
      response["errorDescription"] = errorDescription
    }

    let callback = completion
    completion = nil
    connection?.stateUpdateHandler = nil
    connection?.cancel()
    connection = nil

    DispatchQueue.main.async {
      callback?(response)
    }
  }
}
