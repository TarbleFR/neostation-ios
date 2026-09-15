import Foundation
import NetworkExtension
import os.log

/// Device-local RemotePairing route. Every lifecycle mutation, packet callback
/// and watchdog tick is serialized; a completed stop cannot be undone by an
/// older setTunnelNetworkSettings callback.
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
  // Access only on watchdogQueue, including NetworkExtension callbacks.
  private var stopped = true
  private var generation: UInt64 = 0
  private var startCompletion: ((Error?) -> Void)?
  private var watchdogTimer: DispatchSourceTimer?
  private var lastHeartbeatUptime: TimeInterval = 0

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    watchdogQueue.async {
      // Also makes an unexpected overlapping start settle the older caller.
      self.finishPendingStart(Self.cancelledStartError())
      self.stopWatchdog()
      self.generation &+= 1
      let generation = self.generation
      self.stopped = false
      self.startCompletion = completionHandler
      let provider =
        (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
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
        NEIPv4Route(destinationAddress: peerAddress, subnetMask: "255.255.255.255"),
      ]
      ipv4.excludedRoutes = [.default()]
      let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peerAddress)
      settings.ipv4Settings = ipv4
      settings.mtu = 1500

      self.setTunnelNetworkSettings(settings) { error in
        self.watchdogQueue.async {
          // stopTunnel has already completed the cancelled startup. Do not
          // announce success, restart a reader, or arm a watchdog for it.
          guard self.generation == generation, !self.stopped else { return }
          if let error {
            self.stopped = true
            self.logger.error("Local tunnel settings failed: \(error.localizedDescription, privacy: .public)")
            self.finishPendingStart(error)
            return
          }
          self.logger.info("Device-local JIT tunnel is ready.")
          self.startWatchdog()
          self.readAndReflectPackets()
          self.finishPendingStart(nil)
        }
      }
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    watchdogQueue.async {
      self.generation &+= 1
      self.stopped = true
      self.stopWatchdog()
      self.finishPendingStart(Self.cancelledStartError())
      self.logger.info("Device-local JIT tunnel stopped with reason \(reason.rawValue).")
      completionHandler()
    }
  }

  override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)? = nil
  ) {
    watchdogQueue.async {
      guard !self.stopped, self.startCompletion == nil else {
        completionHandler?(nil)
        return
      }
      if String(data: messageData, encoding: .utf8) == Configuration.heartbeatMessage {
        self.lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
        completionHandler?(Data("alive".utf8))
      } else {
        completionHandler?(Data("ready".utf8))
      }
    }
  }

  private func finishPendingStart(_ error: Error?) {
    dispatchPrecondition(condition: .onQueue(watchdogQueue))
    let completion = startCompletion
    startCompletion = nil
    completion?(error)
  }

  private static func cancelledStartError() -> NSError {
    NSError(
      domain: "NeoStationLocalTunnel",
      code: NSUserCancelledError,
      userInfo: [NSLocalizedDescriptionKey: "Local tunnel startup was cancelled by a newer stop."]
    )
  }

  private func startWatchdog() {
    dispatchPrecondition(condition: .onQueue(watchdogQueue))
    stopWatchdog()
    lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
    let generation = self.generation
    let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
    timer.schedule(
      deadline: .now() + Configuration.watchdogInterval,
      repeating: Configuration.watchdogInterval,
      leeway: .milliseconds(200)
    )
    timer.setEventHandler { [weak self] in
      guard let self, self.generation == generation else { return }
      self.expireHeartbeatIfNeeded(now: ProcessInfo.processInfo.systemUptime)
    }
    watchdogTimer = timer
    timer.resume()
  }

  private func expireHeartbeatIfNeeded(now: TimeInterval) {
    dispatchPrecondition(condition: .onQueue(watchdogQueue))
    guard !stopped else { return }
    let elapsed = now - lastHeartbeatUptime
    guard elapsed >= Configuration.heartbeatTimeout else { return }
    logger.error("NeoStation heartbeat expired after \(elapsed, privacy: .public)s; closing the local tunnel.")
    stopped = true
    generation &+= 1
    stopWatchdog()
    cancelTunnelWithError(nil)
  }

  private func stopWatchdog() {
    dispatchPrecondition(condition: .onQueue(watchdogQueue))
    watchdogTimer?.setEventHandler {}
    watchdogTimer?.cancel()
    watchdogTimer = nil
  }

  private func readAndReflectPackets() {
    dispatchPrecondition(condition: .onQueue(watchdogQueue))
    guard !stopped else { return }
    let generation = self.generation
    packetFlow.readPackets { [weak self] packets, protocols in
      guard let self else { return }
      self.watchdogQueue.async {
        guard !self.stopped, self.generation == generation else { return }
        var reflected = [Data]()
        var reflectedProtocols = [NSNumber]()
        reflected.reserveCapacity(packets.count)
        reflectedProtocols.reserveCapacity(protocols.count)
        for (index, packet) in packets.enumerated() {
          guard index < protocols.count,
                protocols[index].int32Value == AF_INET,
                packet.count >= 20 else { continue }
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
          self.packetFlow.writePackets(reflected, withProtocols: reflectedProtocols)
        }
        self.readAndReflectPackets()
      }
    }
  }
}
