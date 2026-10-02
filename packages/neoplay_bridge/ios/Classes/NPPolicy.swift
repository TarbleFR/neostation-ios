import Foundation

struct NPSize: Equatable { let width: Int; let height: Int }
enum NPPolicy {
    static let version = 1
    static let maxPacket = 4 * 1024 * 1024
    static let maxQueuedBytes = 8 * 1024 * 1024
    static func encodeSize(source: NPSize, display: NPSize, cap: NPSize = NPSize(width: 1920, height: 1080)) -> NPSize {
        guard source.width > 0, source.height > 0, display.width > 0, display.height > 0 else { return NPSize(width: 1280, height: 720) }
        let scale = min(1.0, Double(min(display.width, cap.width)) / Double(source.width), Double(min(display.height, cap.height)) / Double(source.height))
        return NPSize(width: max(2, Int(Double(source.width) * scale) / 2 * 2), height: max(2, Int(Double(source.height) * scale) / 2 * 2))
    }
}

// Tokens fence late network/capture callbacks. Stopping only invalidates NeoPlay.
struct NPSessionFence {
    private(set) var generation = 0
    private(set) var active = false
    mutating func begin() -> Int? { guard !active else { return nil }; generation += 1; active = true; return generation }
    func accepts(_ token: Int) -> Bool { active && token == generation }
    mutating func stop() { generation += 1; active = false }
}

enum NPError: String, Error {
    case busy, unavailable, receiverGone, pairing, network, capture, encoder, backpressure, timeout, cast, wifiRequired
}

// A bounded RAM ring for *encoded* media, not guest memory and not NeoSwap.
final class NPSegmentStore {
    struct Segment { let sequence: Int; let epoch: Int; let duration: Double; let bytes: Data }
    private let lock = NSLock()
    private var initializations: [Int: Data] = [:]
    private var segments: [Segment] = []
    private var epoch = -1
    private var nextSequence = 0
    private let maxBytes: Int
    private let maxSegments: Int
    init(maxBytes: Int = 24 * 1024 * 1024, maxSegments: Int = 24) { self.maxBytes = maxBytes; self.maxSegments = maxSegments }
    func initialize(_ data: Data) throws {
        guard !data.isEmpty, data.count <= NPPolicy.maxPacket else { throw NPError.encoder }
        lock.lock(); defer { lock.unlock() }; epoch += 1; initializations[epoch] = data
        prune()
    }
    func append(_ data: Data, duration: Double) throws {
        guard !data.isEmpty, data.count <= NPPolicy.maxPacket, duration.isFinite, duration > 0, duration < 1.5 else { throw NPError.encoder }
        lock.lock(); defer { lock.unlock() }
        guard epoch >= 0 else { throw NPError.encoder }
        segments.append(Segment(sequence: nextSequence, epoch: epoch, duration: duration, bytes: data)); nextSequence += 1
        prune()
    }
    private func prune() {
        while segments.count > maxSegments || segments.reduce(0, {$0 + $1.bytes.count}) + initializations.values.reduce(0, {$0 + $1.count}) > maxBytes {
            guard !segments.isEmpty else { break }; segments.removeFirst()
        }
        let needed = Set(segments.map(\.epoch) + [epoch]); initializations = initializations.filter { needed.contains($0.key) }
    }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; let visible = segments.suffix(6); return visible.count >= 3 && visible.reduce(0, {$0 + $1.duration}) >= 3 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return segments.count }
    var byteCount: Int { lock.lock(); defer { lock.unlock() }; return segments.reduce(0, {$0 + $1.bytes.count}) + initializations.values.reduce(0, {$0 + $1.count}) }
    func response(_ resource: String) -> (Int, String, Data) {
        lock.lock(); defer { lock.unlock() }
        if resource == "index.m3u8" {
            // RFC 8216: fixed target duration; retain older payloads after playlist eviction.
            let advertised = Array(segments.suffix(6))
            guard let first = advertised.first, advertised.count >= 3, advertised.reduce(0, {$0 + $1.duration}) >= 3 else { return (503, "text/plain", Data()) }
            var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:1", "#EXT-X-MEDIA-SEQUENCE:\(first.sequence)", "#EXT-X-DISCONTINUITY-SEQUENCE:\(first.epoch)"]
            var previous: Int?
            for item in advertised {
                if item.epoch != previous {
                    if previous != nil { lines.append("#EXT-X-DISCONTINUITY") }
                    lines.append("#EXT-X-MAP:URI=\"init-\(item.epoch).mp4\""); previous = item.epoch
                }
                lines += [String(format: "#EXTINF:%.6f,", locale: Locale(identifier: "en_US_POSIX"), item.duration), "segment-\(item.sequence).m4s"]
            }
            return (200, "application/vnd.apple.mpegurl", Data((lines.joined(separator: "\n") + "\n").utf8))
        }
        for (id, data) in initializations where resource == "init-\(id).mp4" { return (200, "video/mp4", data) }
        for item in segments where resource == "segment-\(item.sequence).m4s" { return (200, "video/iso.segment", item.bytes) }
        return (404, "text/plain", Data())
    }
}
