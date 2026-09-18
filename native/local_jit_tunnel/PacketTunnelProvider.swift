import Foundation
import NetworkExtension

/// Minimal device-local packet tunnel used only to expose the RemotePairing
/// endpoint required by StikJIT. It never self-terminates because of a heartbeat,
/// diagnostics, packet backpressure or application lifecycle state.
final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let queue = DispatchQueue(
    label: "com.neogamelab.neostation.localtunnel.packets",
    qos: .userInitiated,
    autoreleaseFrequency: .workItem
  )

  private var generation: UInt64 = 0
  private var running = false
  private var ready = false
  private var readPending = false
  private var pendingStart: ((Error?) -> Void)?
  private var startedAt: TimeInterval = 0
  private var readPackets: UInt64 = 0
  private var writtenPackets: UInt64 = 0
  private var droppedPackets: UInt64 = 0
  private var writeFailures: UInt64 = 0

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    queue.async {
      self.finishPendingStart(Self.cancelledStartError())
      self.generation &+= 1
      let generation = self.generation
      self.running = true
      self.ready = false
      self.readPending = false
      self.startedAt = ProcessInfo.processInfo.systemUptime
      self.readPackets = 0
      self.writtenPackets = 0
      self.droppedPackets = 0
      self.writeFailures = 0
      self.pendingStart = completionHandler

      let provider =
        (self.protocolConfiguration as? NETunnelProviderProtocol)?
        .providerConfiguration
      let interfaceAddress =
        options?["interfaceAddress"] as? String ??
        provider?["interfaceAddress"] as? String ??
        "10.7.1.1"
      let peerAddress =
        options?["peerAddress"] as? String ??
        provider?["peerAddress"] as? String ??
        "10.7.0.1"

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

      self.setTunnelNetworkSettings(settings) { error in
        self.queue.async {
          guard self.generation == generation, self.running else { return }
          if let error {
            self.running = false
            self.ready = false
            self.finishPendingStart(error)
            return
          }

          self.ready = true
          self.readNext()
          self.finishPendingStart(nil)
        }
      }

      // NetworkExtension must eventually resolve startTunnel. If iOS never
      // invokes the setTunnelNetworkSettings callback, fail this startup
      // attempt explicitly instead of leaving the manager waiting for 45 s.
      self.queue.asyncAfter(deadline: .now() + 10) {
        guard
          self.generation == generation,
          self.running,
          !self.ready,
          self.pendingStart != nil
        else {
          return
        }

        self.running = false
        self.ready = false
        self.generation &+= 1
        self.finishPendingStart(Self.networkSettingsTimeoutError())
      }
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    queue.async {
      self.generation &+= 1
      self.running = false
      self.ready = false
      self.readPending = false
      self.finishPendingStart(Self.cancelledStartError())
      completionHandler()
    }
  }

  override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)? = nil
  ) {
    queue.async {
      guard self.running, self.ready else {
        completionHandler?(nil)
        return
      }

      if messageData == Data("heartbeat".utf8) {
        // Compatibility ping only. It has no lifecycle authority.
        completionHandler?(Data("alive".utf8))
        return
      }

      if messageData == Data("vpn-status".utf8) ||
         messageData == Data("vpn271-status".utf8) {
        let payload: [String: Any] = [
          "version": 277,
          "ready": true,
          "readPackets": self.readPackets,
          "writtenPackets": self.writtenPackets,
          "droppedPackets": self.droppedPackets,
          "writeFailures": self.writeFailures,
          "uptime": ProcessInfo.processInfo.systemUptime - self.startedAt,
        ]
        completionHandler?(
          try? JSONSerialization.data(withJSONObject: payload)
        )
        return
      }

      completionHandler?(Data("ready".utf8))
    }
  }

  private func readNext() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard running, ready, !readPending else { return }

    readPending = true
    let generation = self.generation

    packetFlow.readPackets { [weak self] packets, protocols in
      guard let self else { return }

      self.queue.async {
        self.readPending = false
        guard
          self.running,
          self.ready,
          self.generation == generation
        else {
          return
        }

        self.readPackets &+= UInt64(packets.count)
        var reflected = [Data]()
        var families = [NSNumber]()
        reflected.reserveCapacity(packets.count)
        families.reserveCapacity(protocols.count)

        for (index, packet) in packets.enumerated() {
          guard
            index < protocols.count,
            protocols[index].int32Value == AF_INET,
            packet.count >= 20,
            packet[0] >> 4 == 4
          else {
            self.droppedPackets &+= 1
            continue
          }

          let headerLength = Int(packet[0] & 0x0f) * 4
          let totalLength = Int(packet[2]) * 256 + Int(packet[3])
          guard
            headerLength >= 20,
            headerLength <= totalLength,
            totalLength <= packet.count
          else {
            self.droppedPackets &+= 1
            continue
          }

          var copy = packet
          copy.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for offset in 0..<4 {
              let source = bytes[12 + offset]
              bytes[12 + offset] = bytes[16 + offset]
              bytes[16 + offset] = source
            }
          }

          reflected.append(copy)
          families.append(protocols[index])
        }

        guard !reflected.isEmpty else {
          self.readNext()
          return
        }

        if self.packetFlow.writePackets(
          reflected,
          withProtocols: families
        ) {
          self.writtenPackets &+= UInt64(reflected.count)
        } else {
          // Packet backpressure may drop one reflected batch. It must never
          // tear down the user's VPN.
          self.writeFailures &+= 1
          self.droppedPackets &+= UInt64(reflected.count)
        }

        self.readNext()
      }
    }
  }

  private func finishPendingStart(_ error: Error?) {
    let completion = pendingStart
    pendingStart = nil
    completion?(error)
  }

  private static func cancelledStartError() -> NSError {
    NSError(
      domain: "NeoStationLocalTunnel",
      code: NSUserCancelledError,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Local tunnel startup was cancelled by an explicit stop.",
      ]
    )
  }

  private static func networkSettingsTimeoutError() -> NSError {
    NSError(
      domain: "NeoStationLocalTunnel",
      code: 3,
      userInfo: [
        NSLocalizedDescriptionKey:
          "setTunnelNetworkSettings did not complete within 10 seconds.",
      ]
    )
  }
}
