import Darwin
import Flutter
import Foundation
import MetalKit
import QuartzCore
import UIKit

@_silgen_name("csops")
private func neoStationCSOps(
    _ pid: pid_t,
    _ operations: UInt32,
    _ userAddress: UnsafeMutableRawPointer?,
    _ userSize: Int
) -> Int32

private let csOpsStatus: UInt32 = 0
private let csGetTaskAllow: UInt32 = 0x00000004
private let csDebugged: UInt32 = 0x10000000

final class NeoStationDolphinBridge: NSObject, FlutterPlugin {
    private static let launchQueue = DispatchQueue(
        label: "com.neogamelab.neostation.dolphin.launch",
        qos: .userInitiated
    )
    private static let stateLock = NSLock()
    private static var launchInProgress = false
    private static var jitValidatedForProcess = false

    private weak var activeController: DolphinEmulationViewController?
    private var activeLog: DolphinPersistentLog?

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "neostation/dolphin_internal",
            binaryMessenger: registrar.messenger()
        )
        let instance = NeoStationDolphinBridge()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "launchGame":
            launch(call, result: result)
        case "stop":
            DolphinNativeRuntime.shared.stop()
            activeLog?.event(
                stage: "game_lifecycle",
                status: "stop_requested",
                message: "NeoStation requested the embedded Dolphin core to stop."
            )
            activeLog?.writeMarker(state: "stopping")
            DispatchQueue.main.async { [weak self] in
                self?.activeController?.dismiss(animated: true)
                self?.activeController = nil
            }
            result(nil)
        case "pause":
            let paused = (call.arguments as? [String: Any])?["paused"] as? Bool ?? false
            DolphinNativeRuntime.shared.setPaused(paused)
            result(nil)
        case "isRunning":
            result(DolphinNativeRuntime.shared.isRunning)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func launch(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard #available(iOS 26.0, *) else {
            result([
                "success": false,
                "message": "Built-in Dolphin StikJIT requires iOS 26 or later.",
            ])
            return
        }
        guard
            let arguments = call.arguments as? [String: Any],
            let gamePath = arguments["gamePath"] as? String,
            !gamePath.isEmpty,
            let expectedSystem = arguments["expectedSystem"] as? String,
            ["gc", "wii"].contains(expectedSystem.lowercased()),
            let userDirectory = arguments["userDirectory"] as? String,
            !userDirectory.isEmpty,
            let pairingFilePath = arguments["pairingFilePath"] as? String,
            !pairingFilePath.isEmpty,
            let logPath = arguments["logPath"] as? String,
            !logPath.isEmpty,
            let markerPath = arguments["markerPath"] as? String,
            !markerPath.isEmpty
        else {
            result([
                "success": false,
                "message": "Internal Dolphin launch arguments are incomplete.",
            ])
            return
        }

        Self.stateLock.lock()
        if Self.launchInProgress || DolphinNativeRuntime.shared.isRunning {
            Self.stateLock.unlock()
            result([
                "success": false,
                "message": "Another internal Dolphin session is already active.",
            ])
            return
        }
        Self.launchInProgress = true
        Self.stateLock.unlock()

        let log = DolphinPersistentLog(logPath: logPath, markerPath: markerPath)
        activeLog = log
        let readiness = DolphinReadiness()
        log.event(
            stage: "native_entry",
            status: "started",
            message: "NeoStation entered the embedded Dolphin launch coordinator.",
            details: ["pid": Int(getpid()), "system": expectedSystem]
        )

        guard Self.hasGetTaskAllow() else {
            finishFailure(
                message: "This signed NeoStation build does not preserve get-task-allow.",
                readiness: readiness,
                log: log,
                result: result
            )
            return
        }
        log.event(
            stage: "entitlement",
            status: "success",
            message: "The NeoStation host process has get-task-allow."
        )

        guard let device = MTLCreateSystemDefaultDevice(),
              device.makeCommandQueue() != nil else {
            finishFailure(
                message: "Metal is unavailable on this device.",
                readiness: readiness,
                log: log,
                result: result
            )
            return
        }
        log.event(
            stage: "metal_preflight",
            status: "success",
            message: "A Metal device and command queue were created."
        )

        guard let presentingController = Self.topViewController() else {
            finishFailure(
                message: "NeoStation could not obtain its active view controller.",
                readiness: readiness,
                log: log,
                result: result
            )
            return
        }

        let emulationController = DolphinEmulationViewController(device: device)
        activeController = emulationController
        emulationController.onUserClose = { [weak self, weak emulationController] in
            log.event(
                stage: "game_lifecycle",
                status: "user_stop",
                message: "The user stopped the internal Dolphin session."
            )
            log.writeMarker(state: "stopped_by_user")
            self?.activeController = nil
            emulationController?.dismiss(animated: true)
        }
        emulationController.onCoreEnded = { [weak self] in
            log.event(
                stage: "game_lifecycle",
                status: "core_ended",
                message: "The internal Dolphin core left the running state."
            )
            log.writeMarker(state: "ended")
            self?.activeController = nil
        }

        presentingController.present(emulationController, animated: true) {
            Self.launchQueue.async { [weak self, weak emulationController] in
                guard let self, let emulationController else {
                    self?.finishFailure(
                        message: "The internal Dolphin display was released before startup.",
                        readiness: readiness,
                        log: log,
                        result: result
                    )
                    return
                }
                self.performLaunch(
                    gamePath: gamePath,
                    expectedSystem: expectedSystem,
                    userDirectory: userDirectory,
                    pairingFilePath: pairingFilePath,
                    controller: emulationController,
                    readiness: readiness,
                    log: log,
                    result: result
                )
            }
        }
    }

    @available(iOS 26.0, *)
    private func performLaunch(
        gamePath: String,
        expectedSystem: String,
        userDirectory: String,
        pairingFilePath: String,
        controller: DolphinEmulationViewController,
        readiness: DolphinReadiness,
        log: DolphinPersistentLog,
        result: @escaping FlutterResult
    ) {
        do {
            controller.setPreparationStatus("Loading internal Dolphin core…")
            try DolphinNativeRuntime.shared.initialize(
                userDirectory: userDirectory,
                logPath: log.logPath
            )
            log.event(
                stage: "core_loaded",
                status: "success",
                message: "\(DolphinNativeRuntime.shared.version) loaded in NeoStation."
            )

            try DolphinNativeRuntime.shared.validateImage(
                path: gamePath,
                expectedSystem: expectedSystem
            )
            readiness.imageAccepted = true
            log.event(
                stage: "image_validation",
                status: "success",
                message: "Dolphin recognized the selected image and console."
            )

            let pairingURL = URL(fileURLWithPath: pairingFilePath)
            let pairingData = try Data(contentsOf: pairingURL)
            guard pairingData.count >= 128 else {
                throw DolphinBridgeError.pairingFileInvalid
            }
            log.event(
                stage: "pairing_file",
                status: "success",
                message: "The stored pairing file is readable.",
                details: ["bytes": pairingData.count]
            )

            Self.stateLock.lock()
            let cachedJIT = Self.jitValidatedForProcess
            Self.stateLock.unlock()

            if cachedJIT {
                controller.setPreparationStatus("Revalidating Dolphin JIT memory…")
                try DolphinNativeRuntime.shared.prepareLegacyJIT()
                readiness.stikjitConnected = true
                readiness.pidAttached = true
                readiness.legacyHandshakeValidated = true
                readiness.executableMemoryValidated = true
                log.event(
                    stage: "jit_validation",
                    status: "cached_success",
                    message: "The process-local legacy Dolphin JIT arena remains executable."
                )
            } else {
                controller.setPreparationStatus("Connecting StikJIT legacy helper…")
                let helper = DolphinHelperState()
                DolphinJITCoordinator.enableJIT(
                    targetPID: getpid(),
                    pairingData: pairingData,
                    onConnected: {
                        helper.markConnected()
                        log.event(
                            stage: "jit_helper",
                            status: "connected",
                            message: "The built-in StikJIT helper XPC session is active."
                        )
                    },
                    completion: { success, message in
                        helper.finish(success: success, message: message)
                    }
                )

                let attachDeadline = Date().addingTimeInterval(240)
                var attached = false
                while Date() < attachDeadline {
                    if Self.isDebugged() {
                        attached = true
                        break
                    }
                    let snapshot = helper.snapshot()
                    if snapshot.finished && !snapshot.success {
                        throw DolphinBridgeError.stikJIT(snapshot.message)
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                guard attached else {
                    throw DolphinBridgeError.attachTimedOut(helper.snapshot().message)
                }
                readiness.stikjitConnected = true
                log.event(
                    stage: "stikjit_connection",
                    status: "success",
                    message: "StikJIT attached a debugger session to NeoStation."
                )

                readiness.pidAttached = true
                log.event(
                    stage: "pid_attachment",
                    status: "success",
                    message: "NeoStation PID \(getpid()) is attached."
                )

                controller.setPreparationStatus("Validating Dolphin legacy JIT memory…")
                log.event(
                    stage: "legacy_handshake",
                    status: "started",
                    message: "Entering Dolphin BRK #0x69 with the RX address and length."
                )
                try DolphinNativeRuntime.shared.prepareLegacyJIT()
                readiness.legacyHandshakeValidated = true
                readiness.executableMemoryValidated = true
                log.event(
                    stage: "legacy_handshake",
                    status: "success",
                    message: "The legacy breakpoint returned and ARM64 code executed from the RX arena."
                )

                let helperDeadline = Date().addingTimeInterval(60)
                while Date() < helperDeadline && !helper.snapshot().finished {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                let helperResult = helper.snapshot()
                guard helperResult.finished else {
                    throw DolphinBridgeError.helperCompletionTimedOut
                }
                guard helperResult.success else {
                    throw DolphinBridgeError.stikJIT(helperResult.message)
                }
                log.event(
                    stage: "legacy_detach",
                    status: "success",
                    message: helperResult.message
                )

                Self.stateLock.lock()
                Self.jitValidatedForProcess = true
                Self.stateLock.unlock()
            }

            guard let metalLayer = controller.metalView.layer as? CAMetalLayer else {
                throw DolphinBridgeError.metalLayerMissing
            }
            let layerPointer = Unmanaged.passUnretained(metalLayer).toOpaque()
            let scale = Double(UIScreen.main.scale)

            controller.setPreparationStatus("Starting Dolphin JITARM64 + Metal…")
            try DolphinNativeRuntime.shared.launch(
                path: gamePath,
                expectedSystem: expectedSystem,
                metalLayer: layerPointer,
                scale: scale
            )

            // The native call returns only after BootCore is running, the CPU
            // core is JITARM64 and Dolphin's Metal presenter exists.
            readiness.jitArm64Initialized = true
            readiness.metalInitialized = true
            readiness.gameSubmitted = true
            log.event(
                stage: "launch_authorization",
                status: "success",
                message: "All strict readiness gates passed; the game is running."
            )
            log.writeMarker(
                state: "running",
                extra: ["readiness": readiness.dictionary]
            )
            controller.markRunning()

            DispatchQueue.main.async {
                Self.releaseLaunchGuard()
                result(readiness.dictionary.merging([
                    "success": true,
                    "message": "Internal Dolphin started with JITARM64 and Metal.",
                    "pid": Int(getpid()),
                    "runtime": DolphinNativeRuntime.shared.version,
                    "logPath": log.logPath,
                ]) { _, new in new })
            }
        } catch {
            finishFailure(
                message: error.localizedDescription,
                readiness: readiness,
                log: log,
                result: result
            )
        }
    }

    private func finishFailure(
        message: String,
        readiness: DolphinReadiness,
        log: DolphinPersistentLog,
        result: @escaping FlutterResult
    ) {
        log.event(
            stage: "launch_authorization",
            status: "blocked",
            message: message,
            details: ["readiness": readiness.dictionary]
        )
        log.writeMarker(
            state: "blocked",
            extra: ["message": message, "readiness": readiness.dictionary]
        )
        DispatchQueue.main.async { [weak self] in
            self?.activeController?.showFailure(message)
            self?.activeController?.dismiss(animated: true)
            self?.activeController = nil
            Self.releaseLaunchGuard()
            result(readiness.dictionary.merging([
                "success": false,
                "message": message,
                "logPath": log.logPath,
            ]) { _, new in new })
        }
    }

    private static func releaseLaunchGuard() {
        stateLock.lock()
        launchInProgress = false
        stateLock.unlock()
    }

    private static func codeSigningFlags() -> UInt32? {
        var flags: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &flags) { pointer in
            neoStationCSOps(
                getpid(),
                csOpsStatus,
                UnsafeMutableRawPointer(pointer),
                MemoryLayout<UInt32>.size
            )
        }
        return status == 0 ? flags : nil
    }

    private static func hasGetTaskAllow() -> Bool {
        guard let flags = codeSigningFlags() else { return false }
        return (flags & csGetTaskAllow) != 0
    }

    private static func isDebugged() -> Bool {
        guard let flags = codeSigningFlags() else { return false }
        return (flags & csDebugged) != 0
    }

    private static func topViewController(
        from root: UIViewController? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })?
            .rootViewController
    ) -> UIViewController? {
        if let navigation = root as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = root as? UITabBarController,
           let selected = tab.selectedViewController {
            return topViewController(from: selected)
        }
        if let presented = root?.presentedViewController {
            return topViewController(from: presented)
        }
        return root
    }
}

private final class DolphinReadiness {
    var stikjitConnected = false
    var pidAttached = false
    var legacyHandshakeValidated = false
    var executableMemoryValidated = false
    var jitArm64Initialized = false
    var metalInitialized = false
    var imageAccepted = false
    var gameSubmitted = false

    var dictionary: [String: Any] {
        [
            "stikjitConnected": stikjitConnected,
            "pidAttached": pidAttached,
            "legacyHandshakeValidated": legacyHandshakeValidated,
            "executableMemoryValidated": executableMemoryValidated,
            "jitArm64Initialized": jitArm64Initialized,
            "metalInitialized": metalInitialized,
            "imageAccepted": imageAccepted,
            "gameSubmitted": gameSubmitted,
        ]
    }
}

private final class DolphinHelperState {
    private let lock = NSLock()
    private var connected = false
    private var finished = false
    private var success = false
    private var message = "StikJIT helper has not completed."

    func markConnected() {
        lock.lock()
        connected = true
        lock.unlock()
    }

    func finish(success: Bool, message: String) {
        lock.lock()
        finished = true
        self.success = success
        self.message = message
        lock.unlock()
    }

    func snapshot() -> (connected: Bool, finished: Bool, success: Bool, message: String) {
        lock.lock()
        defer { lock.unlock() }
        return (connected, finished, success, message)
    }
}

private final class DolphinPersistentLog {
    let logPath: String
    private let markerPath: String
    private let lock = NSLock()

    init(logPath: String, markerPath: String) {
        self.logPath = logPath
        self.markerPath = markerPath
    }

    func event(
        stage: String,
        status: String,
        message: String,
        details: [String: Any] = [:]
    ) {
        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "component": "DolphinNative",
            "stage": stage,
            "status": status,
            "message": message,
            "details": details,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")

        lock.lock()
        defer { lock.unlock() }
        let url = URL(fileURLWithPath: logPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.synchronize()
        } catch {
            NSLog("[DolphinInternal] failed to persist log: %@", error.localizedDescription)
        }
    }

    func writeMarker(state: String, extra: [String: Any] = [:]) {
        var payload: [String: Any] = [
            "schema": 1,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "state": state,
            "logPath": logPath,
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return
        }
        let url = URL(fileURLWithPath: markerPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

private enum DolphinBridgeError: LocalizedError {
    case pairingFileInvalid
    case stikJIT(String)
    case attachTimedOut(String)
    case helperCompletionTimedOut
    case metalLayerMissing

    var errorDescription: String? {
        switch self {
        case .pairingFileInvalid:
            return "The stored pairing file is invalid or empty."
        case .stikJIT(let message):
            return "StikJIT failed: \(message)"
        case .attachTimedOut(let message):
            return "StikJIT did not attach to the NeoStation PID: \(message)"
        case .helperCompletionTimedOut:
            return "The legacy StikJIT helper did not complete after the breakpoint returned."
        case .metalLayerMissing:
            return "NeoStation could not provide Dolphin with a CAMetalLayer."
        }
    }
}
