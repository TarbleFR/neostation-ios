import Foundation
import NetworkExtension

/// NEOSTATION_VPN_DATAPLANE_271. The route is owned by this extension, not
/// by the debugged app's heartbeat. Explicit OFF and iOS stop remain final.
final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let queue = DispatchQueue(label: "neostation.vpn271.packets", qos: .userInitiated,
                                     autoreleaseFrequency: .workItem)
  private var epoch: UInt64 = 0
  private var running = false
  private var ready = false
  private var readPending = false
  private var pendingStart: ((Error?) -> Void)?
  private var started: TimeInterval = 0
  private var readCount: UInt64 = 0
  private var writtenCount: UInt64 = 0
  private var droppedCount: UInt64 = 0
  private var writeFailures: UInt64 = 0

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    queue.async {
      self.finishStart(self.failure("startup superseded", code: 2))
      self.epoch &+= 1
      let epoch = self.epoch
      self.running = true; self.ready = false
      self.started = ProcessInfo.processInfo.systemUptime
      self.readCount = 0; self.writtenCount = 0; self.droppedCount = 0; self.writeFailures = 0
      self.pendingStart = completionHandler
      // Fixed device-local /32 route. Do not intercept internet or DNS.
      let ipv4 = NEIPv4Settings(addresses: ["10.7.1.1"], subnetMasks: ["255.255.255.0"])
      ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")]
      ipv4.excludedRoutes = [.default()]
      let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
      settings.ipv4Settings = ipv4; settings.mtu = 1500
      self.setTunnelNetworkSettings(settings) { error in
        self.queue.async {
          guard self.running, self.epoch == epoch, self.pendingStart != nil else { return }
          if let error { self.running = false; self.finishStart(error); return }
          self.ready = true
          self.readNext()
          self.finishStart(nil)
        }
      }
      self.queue.asyncAfter(deadline: .now() + 10) {
        guard self.epoch == epoch, self.pendingStart != nil else { return }
        self.running = false; self.ready = false; self.epoch &+= 1
        self.finishStart(self.failure("network settings callback missing after 10s", code: 3))
      }
    }
  }
  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    queue.async {
      self.epoch &+= 1; self.running = false; self.ready = false
      self.finishStart(self.failure("startup cancelled by stop", code: 2))
      completionHandler()
    }
  }
  private func finishStart(_ error: Error?) {
    let completion = pendingStart; pendingStart = nil; completion?(error)
  }
  private func failure(_ detail: String, code: Int) -> NSError {
    NSError(domain: "NeoStationVPN271", code: code, userInfo: [NSLocalizedDescriptionKey: detail])
  }
  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    queue.async {
      guard self.ready, self.running else { completionHandler?(nil); return }
      if messageData == Data("heartbeat".utf8) {
        // Compatibility ping only. It does not extend a lease or gate packets.
        completionHandler?(Data("alive".utf8)); return
      }
      guard messageData == Data("vpn271-status".utf8) else { completionHandler?(nil); return }
      completionHandler?(try? JSONSerialization.data(withJSONObject: [
        "version": 271, "ready": true,
        "readPackets": self.readCount, "writtenPackets": self.writtenCount,
        "droppedPackets": self.droppedCount, "writeFailures": self.writeFailures,
        "uptime": ProcessInfo.processInfo.systemUptime - self.started,
      ]))
    }
  }
  private func readNext() {
    guard running, ready, !readPending else { return }
    readPending = true
    let epoch = self.epoch
    packetFlow.readPackets { [weak self] packets, protocols in
      guard let self else { return }
      self.queue.async {
        self.readPending = false
        guard self.running, self.ready else { return }
        // One outstanding read even across stop/start. Never write old packets.
        guard self.epoch == epoch else { self.readNext(); return }
        self.readCount &+= UInt64(packets.count)
        var reflected = [Data](), families = [NSNumber]()
        for (index, packet) in packets.enumerated() {
          guard index < protocols.count, protocols[index].int32Value == AF_INET,
                packet.count >= 20, packet[0] >> 4 == 4 else { self.droppedCount &+= 1; continue }
          let headerLength = Int(packet[0] & 0x0f) * 4
          let length = Int(packet[2]) * 256 + Int(packet[3])
          guard headerLength >= 20, headerLength <= length, length <= packet.count else {
            self.droppedCount &+= 1; continue
          }
          var copy = packet
          copy.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for offset in 0..<4 { let source = bytes[12+offset]; bytes[12+offset] = bytes[16+offset]; bytes[16+offset] = source }
          }
          reflected.append(copy); families.append(protocols[index])
        }
        if reflected.isEmpty { self.readNext(); return }
        self.deliver(reflected, families, epoch: epoch, attempt: 0)
      }
    }
  }
  private func deliver(_ packets: [Data], _ families: [NSNumber], epoch: UInt64, attempt: Int) {
    guard running, ready, self.epoch == epoch else { return }
    if packetFlow.writePackets(packets, withProtocols: families) {
      writtenCount &+= UInt64(packets.count); readNext()
    } else {
      writeFailures &+= 1
      guard attempt < 3 else {
        // NEOSTATION_VPN_PERSISTENCE_275: transient packet backpressure must
        // never tear down a user-enabled local tunnel. Drop this batch only.
        droppedCount &+= UInt64(packets.count)
        readNext()
        return
      }
      queue.asyncAfter(deadline: .now() + .milliseconds(10 * (attempt + 1))) {
        self.deliver(packets, families, epoch: epoch, attempt: attempt + 1)
      }
    }
  }
}
