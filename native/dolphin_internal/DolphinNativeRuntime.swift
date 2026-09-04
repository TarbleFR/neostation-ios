import Darwin
import Foundation

final class DolphinNativeRuntime {
    static let shared = DolphinNativeRuntime()

    private typealias VersionFn = @convention(c) () -> UnsafePointer<CChar>?
    private typealias InitializeFn = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafeMutablePointer<CChar>?,
        Int
    ) -> Int32
    private typealias ValidateImageFn = @convention(c) (
        UnsafePointer<CChar>?,
        Int32,
        UnsafeMutablePointer<CChar>?,
        Int
    ) -> Int32
    private typealias PrepareJITFn = @convention(c) (
        UnsafeMutablePointer<CChar>?,
        Int
    ) -> Int32
    private typealias LaunchFn = @convention(c) (
        UnsafePointer<CChar>?,
        Int32,
        UnsafeMutableRawPointer?,
        Double,
        UnsafeMutablePointer<CChar>?,
        Int
    ) -> Int32
    private typealias IsRunningFn = @convention(c) () -> Int32
    private typealias PauseFn = @convention(c) (Int32) -> Void
    private typealias StopFn = @convention(c) () -> Void

    private var handle: UnsafeMutableRawPointer?
    private var versionFn: VersionFn?
    private var initializeFn: InitializeFn?
    private var validateImageFn: ValidateImageFn?
    private var prepareJITFn: PrepareJITFn?
    private var launchFn: LaunchFn?
    private var isRunningFn: IsRunningFn?
    private var pauseFn: PauseFn?
    private var stopFn: StopFn?

    private init() {}

    var version: String {
        guard let pointer = versionFn?() else { return "unloaded" }
        return String(cString: pointer)
    }

    func load() throws {
        if handle != nil { return }

        let candidates = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libdolphin.dylib"),
            Bundle.main.bundleURL.appendingPathComponent("Frameworks/libdolphin.dylib"),
            Bundle.main.bundleURL.appendingPathComponent("libdolphin.dylib"),
        ].compactMap { $0 }

        var lastError = "No embedded Dolphin path was available."
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let opened = dlopen(candidate.path, RTLD_NOW | RTLD_GLOBAL) {
                handle = opened
                break
            }
            if let error = dlerror() {
                lastError = String(cString: error)
            }
        }
        guard let handle else {
            throw DolphinNativeRuntimeError.loadFailed(lastError)
        }

        versionFn = try symbol("neostation_dolphin_bridge_version", in: handle)
        initializeFn = try symbol("neostation_dolphin_initialize", in: handle)
        validateImageFn = try symbol("neostation_dolphin_validate_image", in: handle)
        prepareJITFn = try symbol("neostation_dolphin_prepare_legacy_jit", in: handle)
        launchFn = try symbol("neostation_dolphin_launch", in: handle)
        isRunningFn = try symbol("neostation_dolphin_is_running", in: handle)
        pauseFn = try symbol("neostation_dolphin_set_paused", in: handle)
        stopFn = try symbol("neostation_dolphin_stop", in: handle)
    }

    func initialize(userDirectory: String, logPath: String) throws {
        try load()
        guard let initializeFn else {
            throw DolphinNativeRuntimeError.symbolMissing("neostation_dolphin_initialize")
        }
        try callWithErrorBuffer { error, capacity in
            userDirectory.withCString { userDirectoryPointer in
                logPath.withCString { logPathPointer in
                    initializeFn(
                        userDirectoryPointer,
                        logPathPointer,
                        error,
                        capacity
                    )
                }
            }
        }
    }

    func validateImage(path: String, expectedSystem: String) throws {
        try load()
        guard let validateImageFn else {
            throw DolphinNativeRuntimeError.symbolMissing("neostation_dolphin_validate_image")
        }
        let system: Int32
        switch expectedSystem.lowercased() {
        case "gc": system = 0
        case "wii": system = 1
        default:
            throw DolphinNativeRuntimeError.invalidSystem(expectedSystem)
        }
        try callWithErrorBuffer { error, capacity in
            path.withCString { pathPointer in
                validateImageFn(pathPointer, system, error, capacity)
            }
        }
    }

    func prepareLegacyJIT() throws {
        try load()
        guard let prepareJITFn else {
            throw DolphinNativeRuntimeError.symbolMissing(
                "neostation_dolphin_prepare_legacy_jit"
            )
        }
        try callWithErrorBuffer { error, capacity in
            prepareJITFn(error, capacity)
        }
    }

    func launch(
        path: String,
        expectedSystem: String,
        metalLayer: UnsafeMutableRawPointer,
        scale: Double
    ) throws {
        try load()
        guard let launchFn else {
            throw DolphinNativeRuntimeError.symbolMissing("neostation_dolphin_launch")
        }
        let system: Int32
        switch expectedSystem.lowercased() {
        case "gc": system = 0
        case "wii": system = 1
        default:
            throw DolphinNativeRuntimeError.invalidSystem(expectedSystem)
        }
        try callWithErrorBuffer { error, capacity in
            path.withCString { pathPointer in
                launchFn(
                    pathPointer,
                    system,
                    metalLayer,
                    scale,
                    error,
                    capacity
                )
            }
        }
    }

    var isRunning: Bool {
        (isRunningFn?() ?? 0) == 1
    }

    func setPaused(_ paused: Bool) {
        pauseFn?(paused ? 1 : 0)
    }

    func stop() {
        stopFn?()
    }

    private func symbol<T>(
        _ name: String,
        in handle: UnsafeMutableRawPointer
    ) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw DolphinNativeRuntimeError.symbolMissing(name)
        }
        return unsafeBitCast(pointer, to: T.self)
    }

    private func callWithErrorBuffer(
        _ body: (UnsafeMutablePointer<CChar>, Int) -> Int32
    ) throws {
        var buffer = [CChar](repeating: 0, count: 4096)
        let status = buffer.withUnsafeMutableBufferPointer { pointer in
            body(pointer.baseAddress!, pointer.count)
        }
        guard status == 1 else {
            let message = buffer.withUnsafeBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else {
                    return "Embedded Dolphin returned no diagnostic."
                }
                return String(cString: baseAddress)
            }
            throw DolphinNativeRuntimeError.coreRejected(
                message.isEmpty ? "Embedded Dolphin rejected the operation." : message
            )
        }
    }
}

enum DolphinNativeRuntimeError: LocalizedError {
    case loadFailed(String)
    case symbolMissing(String)
    case invalidSystem(String)
    case coreRejected(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let message):
            return "Embedded Dolphin could not be loaded: \(message)"
        case .symbolMissing(let symbol):
            return "Embedded Dolphin is missing required symbol \(symbol)."
        case .invalidSystem(let system):
            return "Unsupported Dolphin playlist \(system)."
        case .coreRejected(let message):
            return message
        }
    }
}
