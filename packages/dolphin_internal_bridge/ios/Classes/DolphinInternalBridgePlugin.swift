import Darwin
import Flutter
import Foundation
import MetalKit
import QuartzCore
import StikJIT
import UIKit

private let nsCSOpsStatus: UInt32 = 0
private let nsCSDebugged: Int32 = 0x10000000

@_silgen_name("csops")
private func nsCsops(
  _ pid: pid_t,
  _ operations: UInt32,
  _ userAddress: UnsafeMutableRawPointer?,
  _ userSize: Int
) -> Int32

public final class DolphinInternalBridgePlugin: NSObject, FlutterPlugin {
  private static let workQueue = DispatchQueue(
    label: "com.neogamelab.neostation.dolphin",
    qos: .userInitiated
  )
  private let core = DolphinCoreRuntime()
  private var session: DolphinSessionController?
  private var launching = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "neostation/dolphin_internal",
      binaryMessenger: registrar.messenger()
    )
    let instance = DolphinInternalBridgePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "launchGame": launch(call.arguments, result: result)
    case "pause": core.setPaused(true); result(nil)
    case "resume": core.setPaused(false); result(nil)
    case "stop": stop(result)
    case "status":
      result([
        "running": core.isRunning,
        "launchInProgress": launching,
        "pid": Int(getpid()),
        "engine": "DolphinCore",
        "jitScript": "legacy",
      ])
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func launch(_ raw: Any?, result: @escaping FlutterResult) {
    guard !launching, !core.isRunning else {
      result(error("dolphin_busy", "A Dolphin session is already active.")); return
    }
    guard #available(iOS 17.4, *) else {
      result(error("dolphin_ios", "Internal Dolphin requires iOS 17.4 or later.")); return
    }
    guard
      let args = raw as? [String: Any],
      let gamePath = args["gamePath"] as? String,
      let system = args["expectedSystem"] as? String,
      let userPath = args["userDirectory"] as? String,
      let pairingPath = args["pairingFilePath"] as? String,
      let logPath = args["logPath"] as? String,
      !gamePath.isEmpty, !userPath.isEmpty, !pairingPath.isEmpty, !logPath.isEmpty
    else {
      result(error("dolphin_arguments", "Incomplete Dolphin launch request.")); return
    }
    let normalized = system.lowercased()
    guard normalized == "gc" || normalized == "wii" else {
      result(error("dolphin_route", "Internal Dolphin accepts only GameCube and Wii.")); return
    }
    guard FileManager.default.isReadableFile(atPath: gamePath) else {
      result(error("dolphin_game", "The selected game image is not readable.")); return
    }
    guard FileManager.default.isReadableFile(atPath: pairingPath) else {
      result(error("dolphin_pairing", "The stored pairing file is not readable.")); return
    }
    guard DolphinEntitlements.hasGetTaskAllow else {
      result(error(
        "dolphin_get_task_allow",
        "This signature does not preserve get-task-allow, so StikJIT cannot attach to NeoStation."
      )); return
    }

    launching = true
    Self.workQueue.async { [weak self] in
      guard let self else { return }
      let state = DolphinLaunchState(pid: getpid())
      state.log("route", "success", "Isolated GameCube/Wii route selected.")
      do {
        try self.core.load()
        state.log("core_library", "success", "DolphinCore.framework loaded in NeoStation.")
        try self.core.initialize(userPath, logPath)
        state.log("core_initialization", "success", "Dolphin Core initialized.")

        let systemCode: Int32 = normalized == "gc" ? 0 : 1
        try self.core.validate(gamePath, systemCode)
        state.imageAccepted = true
        state.log("image_validation", "success", "Dolphin accepted the image and platform.")

        let pairingURL = URL(fileURLWithPath: pairingPath)
        let stikRoot = URL(fileURLWithPath: userPath, isDirectory: true)
          .deletingLastPathComponent()
          .appendingPathComponent("StikJIT", isDirectory: true)
        try FileManager.default.createDirectory(at: stikRoot, withIntermediateDirectories: true)
        let config = StikJIT.Configuration.default
        let ddi = DDIPaths.default(in: stikRoot)
        let readiness = StikJIT.prepareDevice(
          pairingFile: pairingURL,
          paths: ddi,
          configuration: config
        ) { stage in state.log("stikjit_prepare", "progress", Self.describe(stage)) }
        switch readiness {
        case .ready(let security):
          state.stikjitConnected = true
          state.txmPresent = security.isTXMPresent
          state.log("stikjit_connection", "success", "Device and DDI are ready.")
        case .unreachable(let reason):
          throw DolphinNativeError.stik("Device unreachable: \(reason)")
        case .preparationFailed(let reason):
          throw DolphinNativeError.stik("Device preparation failed: \(reason)")
        @unknown default:
          throw DolphinNativeError.stik("Unknown device readiness state.")
        }

        let handshake = LegacyHandshake(core: self.core, state: state)
        handshake.start()
        do {
          try StikJIT.enableJIT(
            targetPID: getpid(),
            pairingFile: pairingURL,
            ddiPaths: ddi,
            configuration: config,
            script: .legacy,
            forceScript: true,
            preparationProgress: {
              state.log("stikjit_enable", "progress", Self.describe($0))
            },
            progress: { state.log("stikjit_enable", "progress", $0) }
          )
        } catch {
          handshake.cancel()
          throw DolphinNativeError.stik(error.localizedDescription)
        }
        let probe = handshake.wait(seconds: 30)
        guard probe.success else { throw DolphinNativeError.jit(probe.message) }
        state.legacyHandshakeValidated = true
        state.executableMemoryValidated = true
        state.log("legacy_handshake", "success", probe.message)

        let controller = try DispatchQueue.main.sync { try self.presentSession() }
        defer {
          if !state.gameSubmitted {
            DispatchQueue.main.async { [weak self] in self?.dismissSession() }
          }
        }
        try self.core.launch(
          gamePath,
          systemCode,
          controller.metalLayer,
          controller.renderScale
        )
        state.jitArm64Initialized = true
        state.metalInitialized = true
        state.gameSubmitted = true
        state.success = true
        state.message = "Internal Dolphin started with JITARM64 and Metal."
        state.log("game_submission", "success", "BootCore entered the running state.")
        DispatchQueue.main.async {
          self.launching = false
          result(state.dictionary)
        }
      } catch {
        state.message = error.localizedDescription
        state.log("launch_authorization", "failure", error.localizedDescription)
        self.core.stop()
        DispatchQueue.main.async {
          self.launching = false
          self.dismissSession()
          result(state.dictionary)
        }
      }
    }
  }

  private func stop(_ result: @escaping FlutterResult) {
    Self.workQueue.async { [weak self] in
      self?.core.stop()
      DispatchQueue.main.async {
        self?.dismissSession()
        self?.launching = false
        result(nil)
      }
    }
  }

  private func presentSession() throws -> DolphinSessionController {
    guard let presenter = Self.topController() else {
      throw DolphinNativeError.metal("No active NeoStation view controller.")
    }
    let controller = DolphinSessionController(
      pause: { [weak self] in self?.core.setPaused($0) },
      stop: { [weak self] in self?.stop { _ in } }
    )
    controller.modalPresentationStyle = .fullScreen
    controller.loadViewIfNeeded()
    presenter.present(controller, animated: false)
    session = controller
    return controller
  }

  private func dismissSession() {
    guard let session else { return }
    session.releaseResources()
    session.dismiss(animated: false)
    self.session = nil
  }

  private static func topController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    var controller = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    if let nav = controller as? UINavigationController { return nav.visibleViewController }
    if let tabs = controller as? UITabBarController { return tabs.selectedViewController }
    return controller
  }

  private func error(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }

  @available(iOS 17.4, *)
  private static func describe(_ stage: StikJIT.PreparationStage) -> String {
    switch stage {
    case .checkingReachability: return "Checking RSD reachability."
    case .checkingDDI: return "Checking Developer Disk Image."
    case .downloadingDDI(let fraction, let status):
      return "Downloading DDI \(Int(fraction * 100))%: \(status)"
    case .mountingDDI(let fraction): return "Mounting DDI \(Int(fraction * 100))%."
    case .verifyingDDI: return "Verifying mounted DDI."
    case .ready: return "Device ready for JIT."
    @unknown default: return "Unknown preparation stage."
    }
  }
}

private final class LegacyHandshake: @unchecked Sendable {
  struct Outcome { let success: Bool; let message: String }
  private let core: DolphinCoreRuntime
  private let state: DolphinLaunchState
  private let lock = NSLock()
  private let done = DispatchSemaphore(value: 0)
  private var cancelled = false
  private var outcome = Outcome(success: false, message: "Legacy handshake did not run.")

  init(core: DolphinCoreRuntime, state: DolphinLaunchState) {
    self.core = core
    self.state = state
  }

  func start() {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let deadline = Date().addingTimeInterval(60)
      while Date() < deadline && !self.isCancelled {
        if Self.debugged {
          self.state.pidAttached = true
          self.state.log("pid_attachment", "success", "NeoStation PID reports CS_DEBUGGED.")
          do {
            try self.core.prepareLegacyJIT()
            self.finish(.init(success: true, message: "BRK #0x69 returned and ARM64 code returned 42."))
          } catch {
            self.finish(.init(success: false, message: error.localizedDescription))
          }
          return
        }
        Thread.sleep(forTimeInterval: 0.025)
      }
      self.finish(.init(success: false, message: "NeoStation PID never reported CS_DEBUGGED."))
    }
  }

  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func wait(seconds: Double) -> Outcome {
    if done.wait(timeout: .now() + seconds) == .timedOut {
      return .init(success: false, message: "Timed out waiting for the legacy JIT probe.")
    }
    lock.lock(); defer { lock.unlock() }; return outcome
  }
  private func finish(_ value: Outcome) {
    lock.lock(); outcome = value; lock.unlock(); done.signal()
  }
  private static var debugged: Bool {
    var flags: Int32 = 0
    let status = withUnsafeMutablePointer(to: &flags) {
      nsCsops(getpid(), nsCSOpsStatus, $0, MemoryLayout<Int32>.size)
    }
    return status == 0 && (flags & nsCSDebugged) != 0
  }
}

private final class DolphinCoreRuntime: @unchecked Sendable {
  private typealias InitFn = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int
  ) -> Int32
  private typealias ValidateFn = @convention(c) (
    UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<CChar>?, Int
  ) -> Int32
  private typealias JITFn = @convention(c) (UnsafeMutablePointer<CChar>?, Int) -> Int32
  private typealias LaunchFn = @convention(c) (
    UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?, Double,
    UnsafeMutablePointer<CChar>?, Int
  ) -> Int32
  private typealias RunningFn = @convention(c) () -> Int32
  private typealias PauseFn = @convention(c) (Int32) -> Void
  private typealias StopFn = @convention(c) () -> Void

  private var handle: UnsafeMutableRawPointer?
  private var initializeFn: InitFn?
  private var validateFn: ValidateFn?
  private var jitFn: JITFn?
  private var launchFn: LaunchFn?
  private var runningFn: RunningFn?
  private var pauseFn: PauseFn?
  private var stopFn: StopFn?
  var isRunning: Bool { runningFn?() == 1 }

  func load() throws {
    if handle != nil { return }
    guard let root = Bundle.main.privateFrameworksURL else {
      throw DolphinNativeError.core("Frameworks directory is unavailable.")
    }
    let binary = root.appendingPathComponent("DolphinCore.framework/DolphinCore")
    guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
      let detail = dlerror().map { String(cString: $0) } ?? "Unknown loader error."
      throw DolphinNativeError.core(detail)
    }
    self.handle = handle
    initializeFn = try symbol("neostation_dolphin_initialize", InitFn.self)
    validateFn = try symbol("neostation_dolphin_validate_image", ValidateFn.self)
    jitFn = try symbol("neostation_dolphin_prepare_legacy_jit", JITFn.self)
    launchFn = try symbol("neostation_dolphin_launch", LaunchFn.self)
    runningFn = try symbol("neostation_dolphin_is_running", RunningFn.self)
    pauseFn = try symbol("neostation_dolphin_set_paused", PauseFn.self)
    stopFn = try symbol("neostation_dolphin_stop", StopFn.self)
  }

  func initialize(_ user: String, _ log: String) throws {
    guard let fn = initializeFn else { throw DolphinNativeError.core("Initialize symbol missing.") }
    try call { buffer, count in
      user.withCString { userValue in
        log.withCString { logValue in fn(userValue, logValue, buffer, count) }
      }
    }
  }
  func validate(_ path: String, _ system: Int32) throws {
    guard let fn = validateFn else { throw DolphinNativeError.core("Validation symbol missing.") }
    try call { buffer, count in path.withCString { fn($0, system, buffer, count) } }
  }
  func prepareLegacyJIT() throws {
    guard let fn = jitFn else { throw DolphinNativeError.core("Legacy JIT symbol missing.") }
    try call { fn($0, $1) }
  }
  func launch(_ path: String, _ system: Int32, _ layer: CAMetalLayer, _ scale: Double) throws {
    guard let fn = launchFn else { throw DolphinNativeError.core("Launch symbol missing.") }
    let pointer = Unmanaged.passUnretained(layer).toOpaque()
    try call { buffer, count in path.withCString { fn($0, system, pointer, scale, buffer, count) } }
  }
  func setPaused(_ paused: Bool) { pauseFn?(paused ? 1 : 0) }
  func stop() { stopFn?() }

  private func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
    guard let handle, let value = dlsym(handle, name) else {
      throw DolphinNativeError.core("Missing symbol \(name).")
    }
    return unsafeBitCast(value, to: type)
  }
  private func call(_ body: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
    var error = [CChar](repeating: 0, count: 2048)
    let ok = error.withUnsafeMutableBufferPointer { body($0.baseAddress!, $0.count) }
    guard ok == 1 else {
      let message = error.withUnsafeBufferPointer {
        $0.baseAddress?.pointee == 0 ? "Unspecified Dolphin failure." : String(cString: $0.baseAddress!)
      }
      throw DolphinNativeError.core(message)
    }
  }
}

private final class DolphinSessionController: UIViewController {
  private let metal = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
  private let pauseHandler: (Bool) -> Void
  private let stopHandler: () -> Void
  private var paused = false
  var metalLayer: CAMetalLayer { metal.layer as! CAMetalLayer }
  var renderScale: Double { Double(view.window?.screen.scale ?? UIScreen.main.scale) }

  init(pause: @escaping (Bool) -> Void, stop: @escaping () -> Void) {
    pauseHandler = pause; stopHandler = stop
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override var prefersStatusBarHidden: Bool { true }
  override var prefersHomeIndicatorAutoHidden: Bool { true }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    metal.translatesAutoresizingMaskIntoConstraints = false
    metal.preferredFramesPerSecond = 120
    view.addSubview(metal)
    NSLayoutConstraint.activate([
      metal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      metal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      metal.topAnchor.constraint(equalTo: view.topAnchor),
      metal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    let back = button("Back", #selector(stopPressed))
    let pause = button("Pause", #selector(pausePressed))
    let stop = button("Stop", #selector(stopPressed))
    let stack = UIStackView(arrangedSubviews: [back, pause, stop])
    stack.axis = .horizontal
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
    ])
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(resign),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(active),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }
  private func button(_ title: String, _ action: Selector) -> UIButton {
    let value = UIButton(type: .system)
    value.setTitle(title, for: .normal)
    value.setTitleColor(.white, for: .normal)
    value.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    value.layer.cornerRadius = 10
    value.contentEdgeInsets = .init(top: 9, left: 14, bottom: 9, right: 14)
    value.addTarget(self, action: action, for: .touchUpInside)
    return value
  }
  @objc private func pausePressed(_ sender: UIButton) {
    paused.toggle()
    sender.setTitle(paused ? "Resume" : "Pause", for: .normal)
    pauseHandler(paused)
  }
  @objc private func stopPressed() { stopHandler() }
  @objc private func resign() { if !paused { pauseHandler(true) } }
  @objc private func active() { if !paused { pauseHandler(false) } }
  func releaseResources() {
    NotificationCenter.default.removeObserver(self)
    metal.delegate = nil
    metal.isPaused = true
    metal.removeFromSuperview()
  }
  deinit { NotificationCenter.default.removeObserver(self) }
}

private enum DolphinEntitlements {
  private typealias Create = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
  private typealias Copy = @convention(c) (
    UnsafeMutableRawPointer?, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?
  ) -> Unmanaged<CFTypeRef>?
  static var hasGetTaskAllow: Bool {
    guard let library = dlopen(
      "/System/Library/Frameworks/Security.framework/Security",
      RTLD_NOW
    ) else { return false }
    defer { dlclose(library) }
    guard let c = dlsym(library, "SecTaskCreateFromSelf"),
          let v = dlsym(library, "SecTaskCopyValueForEntitlement") else { return false }
    let create = unsafeBitCast(c, to: Create.self)
    let copy = unsafeBitCast(v, to: Copy.self)
    guard let task = create(kCFAllocatorDefault) else { return false }
    guard let value = copy(
      task,
      "get-task-allow" as CFString,
      nil
    )?.takeRetainedValue() else { return false }
    return CFEqual(value, kCFBooleanTrue)
  }
}

private final class DolphinLaunchState: @unchecked Sendable {
  private let lock = NSLock()
  let pid: pid_t
  var success = false
  var message = "Dolphin launch was not authorized."
  var stikjitConnected = false
  var pidAttached = false
  var legacyHandshakeValidated = false
  var executableMemoryValidated = false
  var jitArm64Initialized = false
  var metalInitialized = false
  var imageAccepted = false
  var gameSubmitted = false
  var txmPresent: Bool?
  private var logs: [[String: String]] = []
  init(pid: pid_t) { self.pid = pid }
  func log(_ stage: String, _ status: String, _ message: String) {
    lock.lock()
    logs.append(["stage": stage, "status": status, "message": message])
    lock.unlock()
  }
  var dictionary: [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    var result: [String: Any] = [
      "success": success,
      "message": message,
      "pid": Int(pid),
      "stikjitConnected": stikjitConnected,
      "pidAttached": pidAttached,
      "legacyHandshakeValidated": legacyHandshakeValidated,
      "executableMemoryValidated": executableMemoryValidated,
      "jitArm64Initialized": jitArm64Initialized,
      "metalInitialized": metalInitialized,
      "imageAccepted": imageAccepted,
      "gameSubmitted": gameSubmitted,
      "jitBackend": "JITARM64",
      "jitScript": "legacy",
      "renderer": "Metal",
      "logs": logs,
    ]
    if let txmPresent { result["txmPresent"] = txmPresent }
    return result
  }
}

private enum DolphinNativeError: LocalizedError {
  case core(String), jit(String), stik(String), metal(String)
  var errorDescription: String? {
    switch self {
    case .core(let message): return "Dolphin Core: \(message)"
    case .jit(let message): return "Dolphin JIT: \(message)"
    case .stik(let message): return "StikJIT: \(message)"
    case .metal(let message): return "Dolphin Metal: \(message)"
    }
  }
}
