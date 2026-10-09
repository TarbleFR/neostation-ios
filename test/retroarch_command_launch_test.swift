import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Scripted RetroArch command port: GET_PLAYLIST pages of two entries so the
/// MORE continuation is exercised; LOAD_CONTENT may switch GET_STATUS.
final class FakeRetroArch {
    var silentPolls = 0
    var status = "GET_STATUS CONTENTLESS"
    var playlists: [String: [String]] = [:]
    var cores = ""
    var statusAfterLoad: String?
    private(set) var loads: [String] = []
    private(set) var commands: [String] = []
    private var polls = 0

    func exchange(_ command: String, _ timeout: TimeInterval) -> String? {
        commands.append(command)
        if command == "GET_STATUS" {
            polls += 1
            return polls > silentPolls ? status + "\n" : nil
        }
        if command.hasPrefix("GET_PLAYLIST ") {
            let argument = command.dropFirst("GET_PLAYLIST ".count)
            let space = argument.lastIndex(of: " ")!
            guard let lines = playlists[String(argument[..<space])],
                  let first = Int(argument[argument.index(after: space)...]) else {
                return "GET_PLAYLIST ERROR no such playlist\n"
            }
            var reply = lines.dropFirst(first).prefix(2).joined(separator: "\n") + "\n"
            if first + 2 < lines.count { reply += "MORE \(first + 2)\n" }
            return reply
        }
        if command == "LIST_CORES" { return cores }
        if command.hasPrefix("LOAD_CONTENT ") {
            loads.append(String(command.dropFirst("LOAD_CONTENT ".count)))
            if let next = statusAfterLoad { status = next }
            return ""
        }
        return nil
    }
}

func launcher(_ fake: FakeRetroArch) -> RetroArchCommandLaunch {
    var clock: TimeInterval = 0
    return RetroArchCommandLaunch(exchange: fake.exchange, now: { clock }, pause: { clock += $0 })
}

let gba = "Nintendo - Game Boy Advance.lpl"
let newBundle = "/private/var/containers/Bundle/Application/NEW/RetroArch.app/Frameworks"
let oldBundle = "/private/var/containers/Bundle/Application/OLD/RetroArch.app/Frameworks"
let library = "/private/var/mobile/Containers/Data/Application/RA/Documents/Bibliothèques "

func gbaPlaylist() -> [String] {
    [
        "0\tActRaiser\t\(library)/snes/ActRaiser.sfc\tDETECT",
        "1\t007\t\(library)/gba/007.zip#007.gba\t\(oldBundle)/mgba_libretro_ios.framework",
        "2\tPokémon\t\(library)/gba/Pokémon #2.gba\tDETECT",
        "3\tMario\t\(library)/gba/Mario.gba\tDETECT",
    ]
}

let installedCores = "Nintendo - Game Boy Advance (mGBA)\t\(newBundle)/mgba_libretro_ios.framework\n"
    + "Nintendo - SNES / SFC (Snes9x - Current)\t\(newBundle)/snes9x_libretro_ios.framework\n"

@main struct Tests {
    static func main() {
        var cases = 0

        // Cold start: silent port, then the exact entry with a core whose
        // bundle moved in a RetroArch update; GET_STATUS confirms the game.
        do {
            let fake = FakeRetroArch()
            fake.silentPolls = 6
            fake.playlists[gba] = gbaPlaylist()
            fake.cores = installedCores
            fake.statusAfterLoad = "GET_STATUS PLAYING game_boy_advance,007"
            let launch = launcher(fake)
            let request = RetroArchCommandRequest(gameId: "\(gba):1", filename: "007.gba", coreName: nil)!
            let outcome = launch.run(request)
            assert(outcome == .started("GET_STATUS PLAYING game_boy_advance,007"), "\(outcome)")
            assert(fake.loads == ["\(newBundle)/mgba_libretro_ios.framework|\(library)/gba/007.zip#007.gba"])
            cases += 1
        }

        // No answer at all (Network Commands off): nothing is loaded.
        do {
            let fake = FakeRetroArch()
            fake.silentPolls = .max
            let outcome = launcher(fake).run(RetroArchCommandRequest(gameId: "\(gba):1", filename: "007.gba", coreName: nil)!)
            assert(outcome == .unavailable && fake.loads.isEmpty)
            assert(!fake.commands.contains { $0.hasPrefix("GET_PLAYLIST") }); cases += 1
        }

        // Playlist changed since the export: the unique name is found through
        // MORE pages, and the export's core name replaces DETECT.
        do {
            let fake = FakeRetroArch()
            fake.playlists[gba] = gbaPlaylist()
            fake.cores = installedCores
            fake.statusAfterLoad = "GET_STATUS PLAYING game_boy_advance,Mario"
            let request = RetroArchCommandRequest(gameId: "\(gba):0", filename: "Mario.gba",
                                                  coreName: "Nintendo - Game Boy Advance (mGBA)")!
            let outcome = launcher(fake).run(request)
            assert(outcome == .started("GET_STATUS PLAYING game_boy_advance,Mario"), "\(outcome)")
            assert(fake.loads == ["\(newBundle)/mgba_libretro_ios.framework|\(library)/gba/Mario.gba"])
            cases += 1
        }

        // A '#' that does not follow an archive extension is part of the name.
        do {
            let fake = FakeRetroArch()
            fake.playlists[gba] = gbaPlaylist()
            fake.cores = installedCores
            fake.statusAfterLoad = "GET_STATUS PLAYING game_boy_advance,Pokémon #2"
            let request = RetroArchCommandRequest(gameId: "\(gba):2", filename: "Pokémon #2.gba",
                                                  coreName: "Nintendo - Game Boy Advance (mGBA)")!
            let outcome = launcher(fake).run(request)
            assert(outcome == .started("GET_STATUS PLAYING game_boy_advance,Pokémon #2"), "\(outcome)")
            cases += 1
        }

        // Unknown core: no LOAD_CONTENT is guessed.
        do {
            let fake = FakeRetroArch()
            fake.playlists[gba] = gbaPlaylist()
            fake.cores = installedCores
            let outcome = launcher(fake).run(RetroArchCommandRequest(gameId: "\(gba):3", filename: "Mario.gba", coreName: nil)!)
            assert(outcome == .failed("core_unresolved") && fake.loads.isEmpty, "\(outcome)"); cases += 1
        }

        // Another game already running: its status is not taken as success.
        do {
            let fake = FakeRetroArch()
            fake.status = "GET_STATUS PLAYING super_nes,ActRaiser"
            fake.playlists[gba] = gbaPlaylist()
            fake.cores = installedCores
            let request = RetroArchCommandRequest(gameId: "\(gba):1", filename: "007.gba", coreName: nil)!
            let stale = launcher(fake).run(request)
            assert(stale == .loadRequested && fake.loads.count == 1, "\(stale)")
            fake.statusAfterLoad = "GET_STATUS PLAYING game_boy_advance,007"
            fake.status = "GET_STATUS PLAYING super_nes,ActRaiser"
            let replaced = launcher(fake).run(request)
            assert(replaced == .started("GET_STATUS PLAYING game_boy_advance,007") && fake.loads.count == 2, "\(replaced)")
            cases += 1
        }

        // Export identity and libretro path rules.
        do {
            let ps2 = RetroArchCommandRequest(gameId: "Sony - PlayStation 2.lpl:7", filename: "a.iso", coreName: nil)
            assert(ps2?.playlist == "Sony - PlayStation 2.lpl" && ps2?.index == 7)
            for bad in ["noindex", ":3", "x.lpl:-1", "x.lpl:"] {
                assert(RetroArchCommandRequest(gameId: bad, filename: "a", coreName: nil) == nil, bad)
            }
            assert(RetroArchCommandRequest(gameId: "x.lpl:1", filename: "", coreName: nil) == nil)
            assert(RetroArchCommandLaunch.launchName("/a/b.zip#c/d.gba") == "c/d.gba")
            assert(RetroArchCommandLaunch.launchName("/a/b.7z#e.gb") == "e.gb")
            assert(RetroArchCommandLaunch.launchName("/a/X.ZIP#y.gba") == "y.gba")
            assert(RetroArchCommandLaunch.launchName("/a/Game #1.sfc") == "Game #1.sfc")
            assert(RetroArchCommandLaunch.coreKey("/x/mgba_libretro_ios.framework/mgba_libretro_ios") == "mgba_libretro_ios")
            assert(RetroArchCommandLaunch.coreKey("/x/mgba_libretro_ios.framework") == "mgba_libretro_ios")
            assert(RetroArchCommandLaunch.coreKey("/x/cores/mgba_libretro_ios.dylib") == "mgba_libretro_ios")
            assert(Set(RetroArchCommandLaunch.contentStems("/a/b.zip#c/d.gba")) == ["d", "b"])
            cases += 1
        }

        // The real loopback transport: one datagram out, the reply back, and
        // a closed port answers nothing.
        do {
            let server = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer -> Bool in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(server, $0, length) == 0 && getsockname(server, $0, &length) == 0
                }
            }
            assert(server >= 0 && bound)
            let port = UInt16(bigEndian: address.sin_port)
            let answered = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 2048)
                var source = sockaddr_storage()
                var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = withUnsafeMutablePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { from in
                        buffer.withUnsafeMutableBytes { recvfrom(server, $0.baseAddress, $0.count, 0, from, &sourceLength) }
                    }
                }
                if count > 0 && String(decoding: buffer.prefix(count), as: UTF8.self) == "GET_STATUS\n" {
                    let reply = Array("GET_STATUS CONTENTLESS\n".utf8)
                    _ = withUnsafePointer(to: &source) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { to in
                            reply.withUnsafeBytes { sendto(server, $0.baseAddress, $0.count, 0, to, sourceLength) }
                        }
                    }
                }
                answered.signal()
            }
            let reply = RetroArchUDPCommandPort.exchange(port: port)("GET_STATUS", 2)
            assert(reply == "GET_STATUS CONTENTLESS\n", String(describing: reply))
            _ = answered.wait(timeout: .now() + 2)
            close(server)
            let started = Date()
            assert(RetroArchUDPCommandPort.exchange(port: port)("GET_STATUS", 0.5) == nil)
            assert(Date().timeIntervalSince(started) < 2)
            cases += 1
        }

        print("RetroArch command launch: \(cases) behavior cases passed; no RetroArch core is executed")
    }
}
