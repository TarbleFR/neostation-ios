import Foundation
import NetworkExtension
import os.log

/// A device-local point-to-point interface used by StikJIT to reach the iOS
/// RemotePairing service. No packet is sent to an external VPN server.
final class PacketTunnelProvider: NEPacketTunnelProvider {
  private enum Configuration {
    static let interfaceAddressKey = "interfaceAddress"
    static let peerAddressKey = "peerAddress"
    static let defaultInterfaceAddress = "10.7.1.1"
    static let defaultPeerAddress = "10.7.0.1"
    static let heartbeatMessage = "heartbeat"
    static let heartbeatTimeout: TimeInterval = 5.0
    static let watchdogInterval: TimeInterval = 1.0
  }

  private let logger = Logger(
    subsystem: "com.neogamelab.neostation.localtunnel",
    category: "PacketTunnelProvider"
  )
  private let watchdogQueue = DispatchQueue(
    label: "com.neogamelab.neostation.localtunnel.watchdog",
    qos: .utility
  )

  private var stopped = false
  private var watchdogTimer: DispatchSourceTimer?
  private var lastHeartbeatUptime: TimeInterval = 0

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    stopped = false
    let provider =
      (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
    let interfaceAddress =
      options?[Configuration.interfaceAddressKey] as? String ??
      provider?[Configuration.interfaceAddressKey] as? String ??
      Configuration.defaultInterfaceAddress
    let peerAddress =
      options?[Configuration.peerAddressKey] as? String ??
      provider?[Configuration.peerAddressKey] as? String ??
      Configuration.defaultPeerAddress

    let ipv4 = NEIPv4Settings(
      addresses: [interfaceAddress],
      subnetMasks: ["255.255.255.255"]
    )
    ipv4.includedRoutes = [
      NEIPv4Route(
        destinationAddress: peerAddress,
        subnetMask: "255.255.255.255"
      ),
    ]
    ipv4.excludedRoutes = [.default()]

    let settings = NEPacketTunnelNetworkSettings(
      tunnelRemoteAddress: peerAddress
    )
    settings.ipv4Settings = ipv4
    settings.mtu = 1500

    setTunnelNetworkSettings(settings) { [weak self] error in
      guard let self else {
        completionHandler(
          NSError(
            domain: "NeoStationLocalTunnel",
            code: 1,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Tunnel provider was released during startup.",
            ]
          )
        )
        return
      }
      if let error {
        self.logger.error(
          "Could not apply local tunnel settings: \(error.localizedDescription, privacy: .public)"
        )
        completionHandler(error)
        return
      }

      self.logger.info("Device-local JIT tunnel is ready.")
      self.startWatchdog()
      self.readAndReflectPackets()
      completionHandler(nil)
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    stopped = true
    stopWatchdog()
    logger.info(
      "Device-local JIT tunnel stopped with reason \(reason.rawValue)."
    )
    completionHandler()
  }

  override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)? = nil
  ) {
    guard String(data: messageData, encoding: .utf8) ==
      Configuration.heartbeatMessage else {
      completionHandler?(Data("ready".utf8))
      return
    }

    watchdogQueue.async { [weak self] in
      guard let self else {
        completionHandler?(nil)
        return
      }
      self.lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
      completionHandler?(Data("alive".utf8))
    }
  }

  private func startWatchdog() {
    watchdogQueue.async { [weak self] in
      guard let self else { return }
      self.watchdogTimer?.cancel()
      self.lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime

      let timer = DispatchSource.makeTimerSource(queue: self.watchdogQueue)
      timer.schedule(
        deadline: .now() + Configuration.watchdogInterval,
        repeating: Configuration.watchdogInterval,
        leeway: .milliseconds(200)
      )
      timer.setEventHandler { [weak self] in
        guard let self, !self.stopped else { return }
        let elapsed =
          ProcessInfo.processInfo.systemUptime - self.lastHeartbeatUptime
        guard elapsed >= Configuration.heartbeatTimeout else { return }

        self.logger.error(
          "NeoStation heartbeat expired after \(elapsed, privacy: .public)s; closing the local tunnel."
        )
        self.stopped = true
        self.watchdogTimer?.setEventHandler {}
        self.watchdogTimer?.cancel()
        self.watchdogTimer = nil
        self.cancelTunnelWithError(nil)
      }
      self.watchdogTimer = timer
      timer.resume()
    }
  }

  private func stopWatchdog() {
    watchdogQueue.async { [weak self] in
      guard let self else { return }
      self.watchdogTimer?.setEventHandler {}
      self.watchdogTimer?.cancel()
      self.watchdogTimer = nil
    }
  }

  private func readAndReflectPackets() {
    guard !stopped else { return }
    packetFlow.readPackets { [weak self] packets, protocols in
      guard let self, !self.stopped else { return }
      var reflected = [Data]()
      var reflectedProtocols = [NSNumber]()
      reflected.reserveCapacity(packets.count)
      reflectedProtocols.reserveCapacity(protocols.count)

      for (index, packet) in packets.enumerated() {
        guard index < protocols.count,
              protocols[index].int32Value == AF_INET,
              packet.count >= 20 else {
          continue
        }
        var copy = packet
        let isIPv4 = copy.withUnsafeMutableBytes { rawBuffer -> Bool in
          guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                bytes[0] >> 4 == 4 else { return false }
          for offset in 0..<4 {
            let source = bytes[12 + offset]
            bytes[12 + offset] = bytes[16 + offset]
            bytes[16 + offset] = source
          }
          return true
        }
        guard isIPv4 else { continue }
        reflected.append(copy)
        reflectedProtocols.append(protocols[index])
      }

      if !reflected.isEmpty {
        self.packetFlow.writePackets(
          reflected,
          withProtocols: reflectedProtocols
        )
      }
      self.readAndReflectPackets()
    }
  }
}
