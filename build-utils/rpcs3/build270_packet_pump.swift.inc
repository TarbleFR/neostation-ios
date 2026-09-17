// NEOSTATION_RPCSS3_PACKET_PUMP_270: never run packet work on the host IPC queue.
// The debugger may suspend the containing app. Its IPC callbacks must not
// prevent the independent Network Extension from carrying debugger traffic.
private final class NeoStationPacketPump {
  typealias Reader = (@escaping ([Data], [NSNumber]) -> Void) -> Void
  typealias Writer = ([Data], [NSNumber]) -> Bool
  fileprivate let queue = DispatchQueue(
    label: "com.neogamelab.neostation.localtunnel.packets270",
    qos: .userInitiated, autoreleaseFrequency: .workItem
  )
  private let read: Reader
  private let write: Writer
  private let failed: (UInt64) -> Void
  private var epoch: UInt64 = 0
  private var running = false

  init(read: @escaping Reader, write: @escaping Writer, failed: @escaping (UInt64) -> Void) {
    self.read = read
    self.write = write
    self.failed = failed
  }

  func start(generation: UInt64) {
    queue.async {
      self.epoch = generation
      self.running = true
      self.next(generation)
    }
  }

  // A stop is ordered after an already submitted batch. Completion proves no
  // older write or scheduled retry can subsequently run for this generation.
  func stop(completion: (() -> Void)? = nil) {
    queue.async {
      self.running = false
      self.epoch &+= 1
      completion?()
    }
  }

  private func next(_ generation: UInt64) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard running, epoch == generation else { return }
    read { [weak self] packets, protocols in
      guard let self else { return }
      self.queue.async {
        guard self.running, self.epoch == generation else { return }
        var reflected = [Data]()
        var families = [NSNumber]()
        reflected.reserveCapacity(packets.count)
        families.reserveCapacity(protocols.count)
        for (index, packet) in packets.enumerated() {
          guard index < protocols.count, protocols[index].int32Value == AF_INET,
                packet.count >= 20, packet[0] >> 4 == 4 else { continue }
          let headerLength = Int(packet[0] & 0x0f) * 4
          guard headerLength >= 20, headerLength <= packet.count else { continue }
          var copy = packet
          copy.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for offset in 0..<4 {
              let source = bytes[12 + offset]
              bytes[12 + offset] = bytes[16 + offset]
              bytes[16 + offset] = source
            }
          }
          reflected.append(copy)
          families.append(protocols[index])
        }
        if reflected.isEmpty { self.next(generation); return }
        self.deliver(reflected, families, generation, attempt: 0)
      }
    }
  }

  private func deliver(_ packets: [Data], _ protocols: [NSNumber],
                       _ generation: UInt64, attempt: Int) {
    guard running, epoch == generation else { return }
    if write(packets, protocols) {
      next(generation)
    } else if attempt < 3 {
      // Retain at most one batch, never accumulate subsequent reads. Repeated
      // IP datagrams are safe for the TCP endpoint, which handles duplicates.
      queue.asyncAfter(deadline: .now() + .milliseconds(10 * (attempt + 1))) {
        self.deliver(packets, protocols, generation, attempt: attempt + 1)
      }
    } else {
      running = false
      failed(generation)
    }
  }
}
// END_NEOSTATION_RPCSS3_PACKET_PUMP_270
