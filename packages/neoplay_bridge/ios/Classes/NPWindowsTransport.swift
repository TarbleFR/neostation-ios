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
    private(set) var framesSupported = false // the receiver accepts the v2 frame protocol
    private var dropped = 0
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = false; config.urlCache = nil
        session = URLSession(configuration: config)
    }
    func connect(host: String, port: Int, pin: String) {
        guard host.hasSuffix(".local.") || host.hasSuffix(".local"), port > 0, port <= 65535 else { onError?(.network); return }
        var components = URLComponents(); components.scheme = "http"; components.host = host; components.port = port; components.path = "/v1/pair"
        guard let url = components.url else { onError?(.network); return }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["v": 1, "pin": pin])
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
    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                guard case .success(.string(let text)) = result, let data = text.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { self.onError?(.network); return }
                if object["type"] as? String == "ready", object["v"] as? Int == 1 {
                    let width = min(7680, max(2, object["width"] as? Int ?? 1280)), height = min(4320, max(2, object["height"] as? Int ?? 720))
                    self.framesSupported = object["frames"] as? Bool == true
                    self.onReady?(NPSize(width: width, height: height)); self.onReady = nil
                }
                if object["type"] as? String == "display" {
                    let width = min(7680, max(2, object["width"] as? Int ?? 1280)), height = min(4320, max(2, object["height"] as? Int ?? 720))
                    self.onDisplay?(NPSize(width: width, height: height))
                }
                if object["type"] as? String == "playback", object["playing"] as? Bool == true { self.onPlayback?() }
                self.receive()
            }
        }
    }
    func send(_ data: Data, initial: Bool) {
        queue.async { [self] in
            guard !stopped else { return }
            guard data.count + 1 <= NPPolicy.maxPacket, bytes + data.count + 1 <= NPPolicy.maxQueuedBytes, packets.count < 16 else { onError?(.backpressure); return }
            var packet = Data([initial ? 1 : 2]); packet.append(data); packets.append(packet); bytes += packet.count; pump()
        }
    }
    // v2 frame protocol: the packet is already typed (first byte = kind). If the
    // link falls behind, pictures and sound are shed rather than queued: the
    // receiver resumes at the next key picture. Configuration is never shed.
    func sendPacket(_ packet: Data) {
        queue.async { [self] in
            guard !stopped, let kind = packet.first else { return }
            guard packet.count <= NPPolicy.maxPacket, bytes + packet.count <= NPPolicy.maxQueuedBytes else { onError?(.backpressure); return }
            if packets.count >= 16 && (kind == 4 || kind == 5) { dropped += 1; if dropped % 60 == 1 { NPLog.record("frames.shed", ["dropped": dropped]) }; return }
            packets.append(packet); bytes += packet.count; pump()
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
    func stop() { queue.async { [self] in stopped = true; onReady = nil; onDisplay = nil; onError = nil; onPlayback = nil; socket?.cancel(with: .normalClosure, reason: nil); socket = nil; packets.removeAll(); session.invalidateAndCancel() } }
}
