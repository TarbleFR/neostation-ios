import Foundation

final class NPWindowsTransport {
    private let queue = DispatchQueue(label: "neoplay.windows")
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var packets: [Data] = []
    private var bytes = 0
    private var sending = false
    private var stopped = false
    var onReady: ((NPSize) -> Void)?
    var onDisplay: ((NPSize) -> Void)?
    var onError: ((NPError) -> Void)?
    var onPlayback: (() -> Void)?
    // Called on the transport queue with the number of packets just shed and their kind.
    var onShed: ((Int, UInt8) -> Void)?
    // The receiver fell behind its decoder and resumes at the next key picture.
    var onKeyRequest: (() -> Void)?
    private(set) var framesSupported = false // the receiver accepts the v2 frame protocol
    // Largest picture the receiver decodes (its `ready` maxWidth/maxHeight);
    // receivers that do not advertise one are MediaSource receivers at 1080p.
    private(set) var receiverMax = NPPolicy.legacyCap
    private(set) var dropped = 0
    private var discontinuity = false // transport queue: a picture was shed since the last one sent
    static let maxQueuedPackets = 16
    static let maxQueuedAudio = 24
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = false; config.urlCache = nil
        session = URLSession(configuration: config)
    }
    // An additive promise, not a new wire version: NPFrameEncoder refuses to
    // start if VideoToolbox rejects AllowFrameReordering=false. Older senders
    // omit it, so receivers must preserve their original SPS unchanged.
    static func pairingBody(pin: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["v": 1, "pin": pin, "noFrameReordering": true])
    }
    func connect(host: String, port: Int, pin: String) {
        guard host.hasSuffix(".local.") || host.hasSuffix(".local"), port > 0, port <= 65535 else { onError?(.network); return }
        var components = URLComponents(); components.scheme = "http"; components.host = host; components.port = port; components.path = "/v1/pair"
        guard let url = components.url else { onError?(.network); return }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? Self.pairingBody(pin: pin)
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                guard error == nil, let data, (response as? HTTPURLResponse)?.statusCode == 200,
                      let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let token = reply["token"] as? String else { self.onError?(.pairing); return }
                components.scheme = "ws"; components.path = "/v1/sender"
                guard let wsURL = components.url else { self.onError?(.network); return }
                var request = URLRequest(url: wsURL); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let socket = self.session.webSocketTask(with: request); socket.maximumMessageSize = 8192; self.socket = socket; socket.resume(); self.receive()
            }
        }.resume()
    }
    private static func size(_ object: [String: Any], _ widthKey: String, _ heightKey: String, fallback: NPSize) -> NPSize {
        let width = object[widthKey] as? Int, height = object[heightKey] as? Int
        return NPSize(width: min(7680, max(2, width ?? fallback.width)), height: min(4320, max(2, height ?? fallback.height)))
    }
    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                guard case .success(.string(let text)) = result, let data = text.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { self.onError?(.network); return }
                self.handle(object)
                self.receive()
            }
        }
    }
    // One receiver message (the transport queue). Internal so the harness drives it without a socket.
    func handle(_ object: [String: Any]) {
        switch object["type"] as? String ?? "" {
        case "ready" where object["v"] as? Int == 1:
            framesSupported = object["frames"] as? Bool == true
            receiverMax = framesSupported ? Self.size(object, "maxWidth", "maxHeight", fallback: NPPolicy.legacyCap) : NPPolicy.legacyCap
            NPLog.record("receiver.ready", ["frames": framesSupported, "maxWidth": receiverMax.width, "maxHeight": receiverMax.height])
            onReady?(Self.size(object, "width", "height", fallback: NPSize(width: 1280, height: 720))); onReady = nil
        case "display": onDisplay?(Self.size(object, "width", "height", fallback: NPSize(width: 1280, height: 720)))
        case "playback" where object["playing"] as? Bool == true: onPlayback?()
        case "keyframe": onKeyRequest?()
        default: break
        }
    }
    func send(_ data: Data, initial: Bool) {
        queue.async { [self] in
            guard !stopped else { return }
            guard data.count + 1 <= NPPolicy.maxPacket, bytes + data.count + 1 <= NPPolicy.maxQueuedBytes, packets.count < Self.maxQueuedPackets else { onError?(.backpressure); return }
            var packet = Data([initial ? 1 : 2]); packet.append(data); packets.append(packet); bytes += packet.count; pump()
        }
    }
    // v2 frame protocol: the packet is already typed (first byte = kind). If the
    // link falls behind, pictures are shed first: the receiver resumes at the
    // next key picture (requested through onShed). Sound is shed only when it
    // alone fills the queue; the receiver fills the hole with silence of the
    // exact length, so a shed never becomes a seek. Configuration is never shed.
    func sendPacket(_ packet: Data) {
        queue.async { [self] in
            guard !stopped, let kind = packet.first else { return }
            guard packet.count <= NPPolicy.maxPacket else { onError?(.backpressure); return }
            let bytesFull = bytes + packet.count > NPPolicy.maxQueuedBytes
            let audioQueued = packets.count >= Self.maxQueuedPackets ? packets.reduce(0) { $0 + ($1.first == 5 ? 1 : 0) } : 0
            // A congested link sheds pictures (count, byte or queue limit); a shed
            // picture is a link signal. Sound is shed only when sound alone fills
            // the queue and is never a key-picture request. Configuration is never shed.
            if kind == 4 && (bytesFull || packets.count >= Self.maxQueuedPackets) || (kind == 5 && audioQueued >= Self.maxQueuedAudio) {
                dropped += 1; if kind == 4 { discontinuity = true }
                if dropped % 60 == 1 { NPLog.record("frames.shed", ["dropped": dropped, "kind": Int(kind)]) }
                onShed?(1, kind); return
            }
            guard !bytesFull else { onError?(.backpressure); return }
            var outgoing = packet
            if kind == 4 && discontinuity && outgoing.count > 9 { outgoing[9] |= 2; discontinuity = false } // bit1: pictures were shed before this one
            packets.append(outgoing); bytes += outgoing.count; pump()
        }
    }
    private func pump() {
        guard !sending, !packets.isEmpty, let socket else { return }; sending = true
        let packet = packets.removeFirst()
        socket.send(.data(packet)) { [weak self] error in
            guard let self else { return }
            self.queue.async { self.bytes -= packet.count; self.sending = false; if error != nil && !self.stopped { self.onError?(.network) }; if !self.stopped { self.pump() } }
        }
    }
    func stop() { queue.async { [self] in stopped = true; onReady = nil; onDisplay = nil; onError = nil; onPlayback = nil; onShed = nil; onKeyRequest = nil; socket?.cancel(with: .normalClosure, reason: nil); socket = nil; packets.removeAll(); session.invalidateAndCancel() } }
}
