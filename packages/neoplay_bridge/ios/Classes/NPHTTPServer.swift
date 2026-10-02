import Foundation
import Network
import Darwin

final class NPHTTPServer {
    private let queue = DispatchQueue(label: "neoplay.http", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let store: NPSegmentStore
    private let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    init(store: NPSegmentStore) { self.store = store }
    func start(_ completion: @escaping (Result<URL, NPError>) -> Void) {
        guard let ip = Self.wifiAddress() else { completion(.failure(.wifiRequired)); return }
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            let listener = try NWListener(using: parameters, on: .any); self.listener = listener
            var answered = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !answered else { return }
                switch state {
                case .ready:
                    answered = true
                    guard let port = listener.port, let url = URL(string: "http://\(ip):\(port.rawValue)/s/\(self.secret)/index.m3u8") else { completion(.failure(.network)); return }
                    completion(.success(url))
                case .failed: answered = true; completion(.failure(.network))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.connections.count < 8 else { connection.cancel(); return }
                let key = ObjectIdentifier(connection); self.connections[key] = connection
                connection.stateUpdateHandler = { [weak self] state in
                    if case .cancelled = state { self?.connections.removeValue(forKey: key) }
                    if case .failed = state { connection.cancel() }
                }
                connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 8) { connection.cancel() }
                self.read(connection, header: Data())
            }
            listener.start(queue: queue)
        } catch { completion(.failure(.network)) }
    }
    private func read(_ connection: NWConnection, header: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var header = header; if let data { header.append(data) }
            guard header.count <= 8192 else { connection.cancel(); return }
            guard let text = String(data: header, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { self.read(connection, header: header) }; return
            }
            let first = text.components(separatedBy: "\r\n")[0].split(separator: " ")
            guard first.count == 3, ["GET", "HEAD", "OPTIONS"].contains(String(first[0])) else { connection.cancel(); return }
            let prefix = "/s/\(self.secret)/", target = String(first[1])
            let result: (Int, String, Data)
            if !target.hasPrefix(prefix) { result = (403, "text/plain", Data()) }
            else if first[0] == "OPTIONS" { result = (204, "text/plain", Data()) }
            else { result = self.store.response(String(target.dropFirst(prefix.count))) }
            let status = result.0, body = result.2
            let reasons = [200:"OK", 204:"No Content", 403:"Forbidden", 404:"Not Found", 503:"Service Unavailable"]
            var response = Data("HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: \(result.1)\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, HEAD, OPTIONS\r\nAccess-Control-Allow-Headers: Range\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            if first[0] != "HEAD" { response.append(body) }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    func stop() { queue.async { [self] in listener?.cancel(); listener = nil; connections.values.forEach { $0.cancel() }; connections.removeAll() } }
    private static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }; defer { freeifaddrs(list) }
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let item = entry {
            defer { entry = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == "en0", let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }
}
