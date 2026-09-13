#!/usr/bin/env python3
"""Patch StikJIT 1.5.0 for current iOS Remote Pairing discovery.

StikJIT 1.5.0 assumes that RemotePairing always listens on port 49152. Newer
iOS releases advertise the active port with Bonjour and may move it between
device-local tunnel sessions. Resolve that service before constructing the default
configuration, while preserving 49152 as the offline/permission fallback.
"""
from pathlib import Path
import sys


MARKER = "NEOSTATION_REMOTE_PAIRING_DISCOVERY_V1"


def patch(source_root: Path) -> None:
    swift_path = source_root / "Sources/StikJIT.swift"
    text = swift_path.read_text()
    if MARKER in text:
        print(f"StikJIT Remote Pairing patch already present: {swift_path}")
        return

    old_import = "import Foundation\n"
    if text.count(old_import) != 1:
        raise ValueError("StikJIT 1.5.0 source drift at Foundation import")
    text = text.replace(old_import, "import Foundation\nimport Network\n", 1)

    old_default = "        public static var `default`: Configuration { Configuration() }\n"
    new_default = f'''        // {MARKER}
        public static var `default`: Configuration {{
            Configuration(
                rsdPort: NeoStationRemotePairingPortResolver.resolve() ?? 49152
            )
        }}
'''
    if text.count(old_default) != 1:
        raise ValueError("StikJIT 1.5.0 source drift at Configuration.default")
    text = text.replace(old_default, new_default, 1)

    text += r'''

/// Resolves the RemotePairing daemon port advertised by the current device.
/// iOS no longer guarantees that the historical 49152 port remains stable.
private enum NeoStationRemotePairingPortResolver {
    private static let serviceType = "_remotepairing._tcp"
    private static let timeout: TimeInterval = 3
    private static let queue = DispatchQueue(
        label: "com.neogamelab.neostation.stikjit.remote-pairing",
        qos: .userInitiated
    )

    static func resolve() -> UInt16? {
        let state = NeoStationRemotePairingResolutionState()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: parameters
        )
        state.install(browser: browser)

        browser.browseResultsChangedHandler = { results, _ in
            guard let endpoint = results.first?.endpoint else { return }
            let connection = NWConnection(to: endpoint, using: parameters)
            guard state.install(connection: connection) else { return }

            connection.pathUpdateHandler = { path in
                guard path.status == .satisfied,
                      let endpoint = path.remoteEndpoint,
                      let port = Self.port(from: endpoint) else { return }
                state.complete(port: port)
            }
            connection.stateUpdateHandler = { connectionState in
                switch connectionState {
                case .ready, .waiting:
                    if let endpoint = connection.currentPath?.remoteEndpoint,
                       let port = Self.port(from: endpoint) {
                        state.complete(port: port)
                    }
                case .failed:
                    state.complete(port: nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        browser.stateUpdateHandler = { browserState in
            if case .failed = browserState {
                state.complete(port: nil)
            }
        }
        browser.start(queue: queue)

        return state.wait(timeout: timeout)
    }

    private static func port(from endpoint: NWEndpoint) -> UInt16? {
        guard case .hostPort(_, let port) = endpoint, port.rawValue > 0 else {
            return nil
        }
        return port.rawValue
    }
}

private final class NeoStationRemotePairingResolutionState {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var resolvedPort: UInt16?
    private var finished = false

    func install(browser: NWBrowser) {
        lock.lock()
        self.browser = browser
        lock.unlock()
    }

    func install(connection: NWConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, self.connection == nil else { return false }
        self.connection = connection
        return true
    }

    func complete(port: UInt16?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        resolvedPort = port
        let browserToCancel = browser
        let connectionToCancel = connection
        lock.unlock()

        browserToCancel?.cancel()
        connectionToCancel?.cancel()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> UInt16? {
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            complete(port: nil)
        }
        lock.lock()
        defer { lock.unlock() }
        return resolvedPort
    }
}
'''

    swift_path.write_text(text)
    print(f"Patched StikJIT Remote Pairing discovery: {swift_path}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_stikjit_remote_pairing.py <StikJIT-1.5.0-source>")
    patch(Path(sys.argv[1]).resolve())
