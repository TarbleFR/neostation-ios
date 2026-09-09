import Foundation
import Network
import StikJIT

private let rpcs3RequestType = "com.neogamelab.neostation.rpcs3-jit-request"

private enum RPCS3JITHelperError: LocalizedError {
    case invalidRequest(String)
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .connection(let message):
            return message
        }
    }
}

private final class RPCS3JITReporter {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.neogamelab.neostation.rpcs3.jit-reporter")
    private let token: String

    init(port: UInt16, token: String) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RPCS3JITHelperError.connection("Invalid NeoStation RPCS3 JIT port.")
        }
        self.token = token
        connection = NWConnection(host: .ipv4(.loopback), port: nwPort, using: .tcp)
    }

    func connect() throws {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var completed = false
        var failure: Error?

        connection.stateUpdateHandler = { state in
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return }
            switch state {
            case .ready:
                completed = true
                semaphore.signal()
            case .failed(let error):
                failure = error
                completed = true
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)

        guard semaphore.wait(timeout: .now() + 8) == .success else {
            connection.cancel()
            throw RPCS3JITHelperError.connection("Timed out connecting to NeoStation for RPCS3 JIT.")
        }
        if let failure {
            connection.cancel()
            throw failure
        }
    }

    func send(
        event: String,
        message: String,
        success: Bool? = nil,
        targetPID: Int32? = nil
    ) throws {
        var payload: [String: Any] = [
            "token": token,
            "event": event,
            "message": message,
        ]
        if let success { payload["success"] = success }
        if let targetPID { payload["targetPID"] = Int(targetPID) }

        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)

        let semaphore = DispatchSemaphore(value: 0)
        var sendError: Error?
        connection.send(content: data, completion: .contentProcessed { error in
            sendError = error
            semaphore.signal()
        })
        guard semaphore.wait(timeout: .now() + 8) == .success else {
            throw RPCS3JITHelperError.connection("Timed out reporting RPCS3 JIT progress to NeoStation.")
        }
        if let sendError { throw sendError }
    }

    func close() {
        connection.cancel()
    }
}

@available(iOS 17.4, *)
@objc(RPCS3JITRequestHandler)
final class RPCS3JITRequestHandler: NSObject, NSExtensionRequestHandling {
    private let workQueue = DispatchQueue(
        label: "com.neogamelab.neostation.rpcs3.jit-helper",
        qos: .userInitiated
    )

    func beginRequest(with context: NSExtensionContext) {
        guard
            let item = context.inputItems.first as? NSExtensionItem,
            let provider = item.attachments?.first(where: {
                $0.hasItemConformingToTypeIdentifier(rpcs3RequestType)
            })
        else {
            context.cancelRequest(
                withError: RPCS3JITHelperError.invalidRequest(
                    "Missing RPCS3 JIT request payload."
                )
            )
            return
        }

        provider.loadItem(forTypeIdentifier: rpcs3RequestType, options: nil) { [weak self] item, error in
            guard let self else { return }
            if let error {
                context.cancelRequest(withError: error)
                return
            }

            let data: Data?
            if let value = item as? Data {
                data = value
            } else if let value = item as? NSData {
                data = value as Data
            } else if let url = item as? URL {
                data = try? Data(contentsOf: url)
            } else {
                data = nil
            }

            guard let data else {
                context.cancelRequest(
                    withError: RPCS3JITHelperError.invalidRequest(
                        "Unreadable RPCS3 JIT request payload."
                    )
                )
                return
            }

            self.workQueue.async {
                self.process(data: data, context: context)
            }
        }
    }

    private func process(data: Data, context: NSExtensionContext) {
        var reporter: RPCS3JITReporter?
        var temporaryPairingURL: URL?

        do {
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                (object["protocolVersion"] as? NSNumber)?.intValue == 1,
                let targetPIDNumber = object["targetPID"] as? NSNumber,
                let portNumber = object["port"] as? NSNumber,
                let token = object["token"] as? String,
                !token.isEmpty,
                let pairingBase64 = object["pairingData"] as? String,
                let pairingData = Data(base64Encoded: pairingBase64),
                (128...(5 * 1024 * 1024)).contains(pairingData.count)
            else {
                throw RPCS3JITHelperError.invalidRequest(
                    "Invalid RPCS3 JIT request fields."
                )
            }

            let targetPID = targetPIDNumber.int32Value
            guard targetPID > 0 else {
                throw RPCS3JITHelperError.invalidRequest("Invalid RPCS3 target PID.")
            }

            let candidatePort = portNumber.intValue
            guard (1...65_535).contains(candidatePort) else {
                throw RPCS3JITHelperError.invalidRequest("Invalid RPCS3 JIT callback port.")
            }

            reporter = try RPCS3JITReporter(port: UInt16(candidatePort), token: token)
            try reporter?.connect()
            try reporter?.send(
                event: "helper_connected",
                message: "RPCS3 JIT helper connected to NeoStation."
            )

            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("NeoStationRPCS3JIT", isDirectory: true)
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            let pairingURL = temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("plist")
            try pairingData.write(to: pairingURL, options: [.atomic, .completeFileProtection])
            temporaryPairingURL = pairingURL

            guard let library = FileManager.default.urls(
                for: .libraryDirectory,
                in: .userDomainMask
            ).first else {
                throw RPCS3JITHelperError.invalidRequest(
                    "RPCS3 JIT helper could not locate its Library directory."
                )
            }
            let stikRoot = library.appendingPathComponent(
                "NeoStationRPCS3StikJIT",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: stikRoot,
                withIntermediateDirectories: true
            )

            try reporter?.send(
                event: "log",
                message: "Starting StikJIT 1.5.0 universal attach for the NeoStation RPCS3 engine."
            )

            let ddiPaths = DDIPaths.default(in: stikRoot)
            let configuration = StikJIT.Configuration.default
            try StikJIT.enableJIT(
                targetPID: targetPID,
                pairingFile: pairingURL,
                ddiPaths: ddiPaths,
                configuration: configuration,
                script: .universal,
                forceScript: false,
                preparationProgress: { stage in
                    try? reporter?.send(
                        event: "log",
                        message: Self.preparationDescription(stage)
                    )
                },
                progress: { message in
                    try? reporter?.send(event: "log", message: message)
                    if Self.isFreshAttachReply(message) {
                        try? reporter?.send(
                            event: "pid_attached",
                            message: "Fresh universal vAttach stop reply received for RPCS3.",
                            targetPID: targetPID
                        )
                    }
                }
            )

            try reporter?.send(
                event: "complete",
                message: "StikJIT completed the RPCS3 universal attach transaction.",
                success: true
            )
            if let temporaryPairingURL {
                try? FileManager.default.removeItem(at: temporaryPairingURL)
            }
            reporter?.close()
            context.completeRequest(returningItems: nil)
        } catch {
            try? reporter?.send(
                event: "complete",
                message: error.localizedDescription,
                success: false
            )
            if let temporaryPairingURL {
                try? FileManager.default.removeItem(at: temporaryPairingURL)
            }
            reporter?.close()
            context.cancelRequest(withError: error)
        }
    }

    private static func isFreshAttachReply(_ message: String) -> Bool {
        guard let marker = message.range(of: "attach_response = ") else {
            return false
        }
        let reply = message[marker.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard reply.count >= 3, reply.first == "T" else { return false }
        return reply.dropFirst().prefix(2).allSatisfy(\.isHexDigit)
    }

    private static func preparationDescription(_ stage: StikJIT.PreparationStage) -> String {
        switch stage {
        case .checkingReachability:
            return "RPCS3 JIT: checking LocalDevVPN/RSD reachability."
        case .checkingDDI:
            return "RPCS3 JIT: checking the Developer Disk Image."
        case .downloadingDDI(let fraction, let status):
            return "RPCS3 JIT: DDI download \(Int(fraction * 100))% — \(status)"
        case .mountingDDI(let fraction):
            return "RPCS3 JIT: mounting DDI \(Int(fraction * 100))%."
        case .verifyingDDI:
            return "RPCS3 JIT: verifying the mounted DDI."
        case .ready:
            return "RPCS3 JIT: device ready; attaching universal.js to NeoStation."
        @unknown default:
            return "RPCS3 JIT: unknown StikJIT preparation stage."
        }
    }
}
