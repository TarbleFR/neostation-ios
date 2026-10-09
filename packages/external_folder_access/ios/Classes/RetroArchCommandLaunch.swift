import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One RetroArch library entry, as exported by RetroArchPlaylistManager:
/// `gameId` is "<playlist file>:<index>" and `filename` its path_basename.
struct RetroArchCommandRequest: Equatable {
    let playlist: String
    let index: Int
    let filename: String
    let coreName: String?

    init?(gameId: String, filename: String, coreName: String?) {
        guard let separator = gameId.lastIndex(of: ":"),
              separator > gameId.startIndex,
              let index = Int(gameId[gameId.index(after: separator)...]),
              index >= 0, !filename.isEmpty else { return nil }
        playlist = String(gameId[..<separator])
        self.index = index
        self.filename = filename
        self.coreName = coreName
    }

    init?(arguments: [String: Any]) {
        guard let gameId = arguments["gameId"] as? String,
              let filename = arguments["filename"] as? String else { return nil }
        self.init(gameId: gameId, filename: filename, coreName: arguments["coreName"] as? String)
    }
}

/// Sends one command line and waits up to `timeout` for one reply; a zero
/// timeout only sends. Nil means no answer (port closed or timeout).
typealias RetroArchCommandExchange = (_ command: String, _ timeout: TimeInterval) -> String?

/// Starts a library entry through RetroArch's network command interface
/// (Settings › Network › Network Commands, UDP 55355 on this device).
///
/// A URL that cold-launches RetroArch is dropped by its scene delegate, and
/// iOS refuses a second URL once the sender left the foreground. Commands are
/// read by RetroArch's own frame loop after any start, and GET_STATUS
/// confirms that the requested content is actually running. The entry and
/// its core are resolved like RetroArch's own retroarch://game route: the
/// entry core, else the playlist default core name from the export.
final class RetroArchCommandLaunch {
    enum Outcome: Equatable {
        case started(String)
        case loadRequested
        case unavailable
        case failed(String)
    }

    struct Entry: Equatable {
        let index: Int
        let label: String
        let path: String
        let core: String
    }

    private let exchange: RetroArchCommandExchange
    private let now: () -> TimeInterval
    private let pause: (TimeInterval) -> Void
    private let isCancelled: () -> Bool
    private(set) var log: [String] = []

    init(exchange: @escaping RetroArchCommandExchange,
         now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         isCancelled: @escaping () -> Bool = { false }) {
        self.exchange = exchange
        self.now = now
        self.pause = pause
        self.isCancelled = isCancelled
    }

    /// Blocking: call it off the main thread once RetroArch was opened.
    func run(_ request: RetroArchCommandRequest, answerWithin: TimeInterval = 10,
             confirmWithin: TimeInterval = 10) -> Outcome {
        guard let ready = poll(until: now() + answerWithin, accept: { _ in true }) else {
            log.append("no answer on the command port")
            return .unavailable
        }
        log.append("ready: \(ready)")
        guard let entry = findEntry(for: request) else { return .failed("playlist_entry_not_found") }
        log.append("entry: \(request.playlist) #\(entry.index) \(entry.path) core=\(entry.core)")
        guard let core = resolveCore(for: entry, coreName: request.coreName) else {
            return .failed("core_unresolved")
        }
        let command = "LOAD_CONTENT \(core)|\(entry.path)"
        // RetroArch reads at most 2047 bytes per datagram.
        guard command.utf8.count < 2000 else { return .failed("command_too_long") }
        _ = exchange(command, 0)
        log.append("sent: LOAD_CONTENT \(core)")
        let wanted = Self.contentStems(entry.path)
        let wasRunning = ready.hasPrefix("GET_STATUS PLAYING") || ready.hasPrefix("GET_STATUS PAUSED")
        if let started = poll(until: now() + confirmWithin, accept: { status in
            guard status.hasPrefix("GET_STATUS PLAYING") || status.hasPrefix("GET_STATUS PAUSED") else {
                return false
            }
            // Content already running before the request must be replaced.
            return !wasRunning || wanted.contains { status.contains($0) }
        }) {
            log.append("confirmed: \(started)")
            return .started(started)
        }
        log.append("LOAD_CONTENT not confirmed in time")
        return .loadRequested
    }

    private func poll(until deadline: TimeInterval, accept: (String) -> Bool) -> String? {
        while !isCancelled() && now() < deadline {
            if let reply = exchange("GET_STATUS", 0.4)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               reply.hasPrefix("GET_STATUS"), accept(reply) {
                return reply
            }
            pause(0.25)
        }
        return nil
    }

    private func findEntry(for request: RetroArchCommandRequest) -> Entry? {
        let named = { (entry: Entry) in Self.launchName(entry.path) == request.filename }
        if let reply = exchange("GET_PLAYLIST \(request.playlist) \(request.index)", 3),
           let first = Self.parsePlaylist(reply).entries.first,
           first.index == request.index, named(first) {
            return first
        }
        // The playlist changed since the export: accept one unambiguous name.
        var first = 0
        var matches: [Entry] = []
        for _ in 0..<50 {
            guard !isCancelled(),
                  let reply = exchange("GET_PLAYLIST \(request.playlist) \(first)", 3) else { break }
            let page = Self.parsePlaylist(reply)
            matches += page.entries.filter(named)
            guard let next = page.more, next > first else { break }
            first = next
        }
        log.append("index \(request.index) moved; name matches=\(matches.count)")
        return matches.count == 1 ? matches[0] : nil
    }

    private func resolveCore(for entry: Entry, coreName: String?) -> String? {
        guard let reply = exchange("LIST_CORES", 3) else { return nil }
        let cores = Self.parseCores(reply)
        if !entry.core.isEmpty && entry.core != "DETECT" {
            if cores.contains(where: { $0.path == entry.core }) { return entry.core }
            // A RetroArch update moves its bundle; the core keeps its name.
            let key = Self.coreKey(entry.core)
            if let moved = cores.first(where: { Self.coreKey($0.path) == key }) { return moved.path }
        }
        if let name = coreName, !name.isEmpty, name != "DETECT",
           let named = cores.first(where: { $0.name == name }) {
            return named.path
        }
        log.append("no installed core for \(entry.core) / \(coreName ?? "-")")
        return nil
    }

    /// GET_PLAYLIST lines: index, label, content path, core path (tabs);
    /// "MORE <next>" when the page is full.
    static func parsePlaylist(_ reply: String) -> (entries: [Entry], more: Int?) {
        var entries: [Entry] = []
        var more: Int?
        for line in reply.split(separator: "\n").map(String.init) {
            if line.hasPrefix("MORE ") {
                more = Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                continue
            }
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 4, let index = Int(fields[0]) else { continue }
            entries.append(Entry(index: index,
                                 label: fields[1..<(fields.count - 2)].joined(separator: "\t"),
                                 path: fields[fields.count - 2],
                                 core: fields[fields.count - 1]))
        }
        return (entries, more)
    }

    /// LIST_CORES lines: display name, tab, path.
    static func parseCores(_ reply: String) -> [(name: String, path: String)] {
        reply.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 2, !fields[1].isEmpty else { return nil }
            return (fields[0], fields[1])
        }
    }

    /// libretro's path_get_archive_delim: the first '#' directly after a
    /// .7z, .zip, .zst, .apk or .rar name; any other '#' is part of a name.
    static func archiveDelimiter(_ path: String) -> String.Index? {
        var search = path.startIndex
        while let hash = path[search...].firstIndex(of: "#") {
            let before = path[..<hash].lowercased()
            let offset = path.distance(from: path.startIndex, to: hash)
            if offset > 3 && before.hasSuffix(".7z") { return hash }
            if offset > 4 && [".zip", ".zst", ".apk", ".rar"].contains(where: { before.hasSuffix($0) }) {
                return hash
            }
            search = path.index(after: hash)
        }
        return nil
    }

    /// libretro's path_basename, which also names the export's `filename`:
    /// everything after an archive delimiter, else the last path component.
    static func launchName(_ path: String) -> String {
        if let hash = archiveDelimiter(path) { return String(path[path.index(after: hash)...]) }
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    /// "…/x_libretro_ios.framework/x_libretro_ios", "…/x.framework" and
    /// "…/x.dylib" all name the core "x_libretro_ios".
    static func coreKey(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if let framework = parts.last(where: { $0.hasSuffix(".framework") }) {
            return String(framework.dropLast(".framework".count))
        }
        let last = parts.last ?? path
        if let dot = last.lastIndex(of: "."), dot > last.startIndex { return String(last[..<dot]) }
        return last
    }

    /// GET_STATUS reports the content basename without its extension.
    static func contentStems(_ path: String) -> [String] {
        let stem = { (name: String) -> String in
            guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return name }
            return String(name[..<dot])
        }
        let last = { (value: String) in value.split(separator: "/").last.map(String.init) ?? value }
        let member = stem(last(launchName(path)))
        guard let hash = archiveDelimiter(path) else { return [member] }
        return Array(Set([member, stem(last(String(path[..<hash])))]))
    }
}

/// RetroArch's network command port on this device only (loopback).
enum RetroArchUDPCommandPort {
    static func exchange(port: UInt16 = 55355) -> RetroArchCommandExchange {
        return { command, timeout in
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { return nil }
            let payload = Array((command + "\n").utf8)
            let sent = payload.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            guard sent == payload.count else { return nil }
            guard timeout > 0 else { return "" }
            let seconds = Int(timeout)
            var wait = timeval(tv_sec: seconds,
                               tv_usec: Int32((timeout - Double(seconds)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let received = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard received > 0 else { return nil }
            return String(decoding: buffer.prefix(received), as: UTF8.self)
        }
    }
}
