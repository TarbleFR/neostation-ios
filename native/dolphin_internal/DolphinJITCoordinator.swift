import ExtensionFoundation
import Foundation
import XPC

@available(iOS 26.0, *)
private final class DolphinJITSession {
    let process: AppExtensionProcess
    let session: XPCSession

    init(process: AppExtensionProcess, session: XPCSession) {
        self.process = process
        self.session = session
    }

    deinit {
        session.cancel(reason: "NeoStation Dolphin JIT request finished")
        process.invalidate()
    }
}

@available(iOS 26.0, *)
enum DolphinJITCoordinator {
    private static var activeSession: AnyObject?

    static func enableJIT(
        targetPID: Int32,
        pairingData: Data,
        onConnected: @escaping () -> Void,
        completion: @escaping (Bool, String) -> Void
    ) {
        Task { @MainActor in
            do {
                let monitor = try await AppExtensionPoint.Monitor(
                    appExtensionPoint: .neoStationDolphinJITHelper
                )
                guard let identity = monitor.identities.first else {
                    throw NSError(
                        domain: "NeoStationDolphinJIT",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The built-in Dolphin JIT helper is missing from this installation."
                        ]
                    )
                }

                let process = try await AppExtensionProcess(
                    configuration: .init(
                        appExtensionIdentity: identity,
                        onInterruption: {
                            DolphinJITCoordinator.activeSession = nil
                        }
                    )
                )
                let xpcSession = try process.makeXPCSession()
                try xpcSession.activate()
                activeSession = DolphinJITSession(
                    process: process,
                    session: xpcSession
                )
                onConnected()

                let request = DolphinJITMessage(
                    targetPID: targetPID,
                    pairingData: pairingData
                )
                try xpcSession.send(request) {
                    (result: Result<DolphinJITMessage.Response, any Error>) in
                    DolphinJITCoordinator.activeSession = nil
                    switch result {
                    case .success(let response):
                        DispatchQueue.main.async {
                            completion(response.success, response.message)
                        }
                    case .failure(let error):
                        DispatchQueue.main.async {
                            completion(false, error.localizedDescription)
                        }
                    }
                }
            } catch {
                activeSession = nil
                completion(false, error.localizedDescription)
            }
        }
    }
}
