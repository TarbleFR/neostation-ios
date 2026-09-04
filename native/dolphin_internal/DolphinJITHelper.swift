import ExtensionFoundation
import Foundation
import StikJIT
import XPC

private struct DolphinJITMessageHandler: XPCPeerHandler {
    func handleIncomingRequest(_ message: DolphinJITMessage) -> (any Encodable)? {
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeoStationDolphinJIT", isDirectory: true)
        let pairingURL = root.appendingPathComponent("pairing.mobiledevicepairing")

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            try message.pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            let paths = DDIPaths.default(in: root)
            NSLog("[DolphinInternal][StikJIT] helper connected; target PID %d", message.targetPID)
            try StikJIT.enableJIT(
                targetPID: message.targetPID,
                pairingFile: pairingURL,
                ddiPaths: paths,
                script: .legacy,
                forceScript: true,
                preparationProgress: { stage in
                    NSLog("[DolphinInternal][StikJIT] preparation: %@", String(describing: stage))
                },
                progress: { line in
                    NSLog("[DolphinInternal][StikJIT] %@", line)
                }
            )
            return DolphinJITMessage.Response(
                success: true,
                message: "StikJIT legacy script completed and detached."
            )
        } catch {
            NSLog("[DolphinInternal][StikJIT] failure: %@", error.localizedDescription)
            return DolphinJITMessage.Response(
                success: false,
                message: error.localizedDescription
            )
        }
    }
}

@main
struct NeoStationDolphinJITHelperExtension: AppExtension {
    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(
            host: "com.neogamelab.neostation",
            name: "DolphinJITHelper"
        )
    }

    var configuration: some AppExtensionConfiguration {
        ConnectionHandler(onSessionRequest: { request in
            request.accept { _ in
                DolphinJITMessageHandler()
            }
        })
    }
}
