import Flutter
import Foundation
import StikJIT
import UIKit

/// Race-free ARMSX2 direct boot.
///
/// `universal.js` resumes the target while `enableJIT` is still blocking and
/// waits for ARMSX2 to call JIT26PrepareRegion/JIT26Detach. If ARMSX2 starts its
/// previously selected ISO at that moment (Automatic Load Last Game + Skip
/// BIOS), the PS2 CPU can race the ISO reader before the requested game URL has
/// been delivered. This bridge removes that race without ever launching
/// NeoStation's own bundle through process_control.
public final class StikjitArmsx2SafeBridgePlugin: NSObject, FlutterPlugin {
  private static let channelName = "neostation/stikjit_armsx2_safe"
  private static let queue = DispatchQueue(
    label: "com.neogamelab.neostation.stikjit.armsx2.safe",
    qos: .userInitiated
  )

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(
      StikjitArmsx2SafeBridgePlugin(),
      channel: channel
    )
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "enableArmsx2JitSafe" else {
      result(FlutterMethodNotImplemented)
      return
    }

    guard #available(iOS 17.4, *) else {
      result(
        FlutterError(
          code: "stikjit_armsx2_safe_unsupported_ios",
          message: "Safe built-in ARMSX2 StikJIT requires iOS 17.4 or newer.",
          details: nil
        )
      )
      return
    }

    guard
      let arguments = call.arguments as? [String: Any],
      let pairingFilePath = arguments["pairingFilePath"] as? String,
      !pairingFilePath.isEmpty,
      let bundleIdHint = arguments["bundleId"] as? String,
      !bundleIdHint.isEmpty,
      let gameURLString = arguments["gameUrl"] as? String,
      let gameURL = URL(string: gameURLString),
      gameURL.scheme?.lowercased() == "armsx2"
    else {
      result(
        FlutterError(
          code: "stikjit_armsx2_safe_invalid_arguments",
          message: "A pairing file, ARMSX2 bundle hint, and armsx2:// game URL are required.",
          details: nil
        )
      )
      return
    }

    let fallbackAutoLoad = arguments["autoLoadLastGame"] as? Bool ?? false
    let backgroundTask = Armsx2SafeBackgroundTask(
      name: "ARMSX2 safe JIT direct boot"
    )

    Self.queue.async {
      Self.runSafeBoot(
        pairingFilePath: pairingFilePath,
        bundleIdHint: bundleIdHint,
        gameURL: gameURL,
        fallbackAutoLoad: fallbackAutoLoad,
        backgroundTask: backgroundTask,
        result: result
      )
    }
  }

  @available(iOS 17.4, *)
  private static func runSafeBoot(
    pairingFilePath: String,
    bundleIdHint: String,
    gameURL: URL,
    fallbackAutoLoad: Bool,
    backgroundTask: Armsx2SafeBackgroundTask,
    result: @escaping FlutterResult
  ) {
    Armsx2NativeDiagnostic.append(
      "STATE: ARMSX2_SAFE_NATIVE_ENTRY hint=\(bundleIdHint) neostationPid=\(getpid()) appState=\(appStateDescription())"
    )

    let pairingFile = URL(fileURLWithPath: pairingFilePath)
    guard FileManager.default.isReadableFile(atPath: pairingFile.path) else {
      finishError(
        Armsx2BridgeError.pairingFileMissing,
        backgroundTask: backgroundTask,
        result: result
      )
      return
    }
    Armsx2NativeDiagnostic.append("STATE: ARMSX2_SAFE_PAIRING_READABLE")

    let configuration = StikJIT.Configuration.default
    var preferenceGuard: Armsx2AutoLoadPreferenceGuard?
    var preferenceToken: Armsx2AutoLoadPreferenceToken?
    var preferenceState: Armsx2AutoLoadPreferenceState?
    var detectedBundleId: String?
    var targetPID: Int32?

    func restorePreference(reason: String) {
      guard let preferenceGuard, let preferenceToken else { return }
      do {
        try preferenceGuard.restore(
          preferenceToken,
          pairingFilePath: pairingFilePath,
          deviceAddress: configuration.deviceAddress,
          rsdPort: configuration.rsdPort
        )
        Armsx2NativeDiagnostic.append(
          "STATE: ARMSX2_SAFE_AUTOLOAD_RESTORED reason=\(reason) key=\(preferenceToken.detectedKey)"
        )
      } catch {
        Armsx2NativeDiagnostic.append(
          "STATE: ARMSX2_SAFE_AUTOLOAD_RESTORE_FAILED reason=\(reason) error=\(error.localizedDescription)"
        )
      }
    }

    defer {
      restorePreference(reason: "safe-boot-exit")
    }

    do {
      // Prepare DDI before ARMSX2 exists so all slow network/mount work happens
      // while NeoStation is still the unequivocal foreground application.
      let applicationSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let stikRoot = applicationSupport.appendingPathComponent(
        "StikJIT",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: stikRoot,
        withIntermediateDirectories: true
      )
      let ddiPaths = DDIPaths.default(in: stikRoot)

      let readiness = StikJIT.prepareDevice(
        pairingFile: pairingFile,
        paths: ddiPaths,
        configuration: configuration
      ) { stage in
        Armsx2NativeDiagnostic.append(
          "PREP: \(preparationDescription(stage))"
        )
      }

      let securityState: StikJIT.DeviceSecurityState
      switch readiness {
      case .ready(let state):
        securityState = state
      case .unreachable(let reason), .preparationFailed(let reason):
        throw Armsx2BridgeError.deviceNotReady(reason)
      @unknown default:
        throw Armsx2BridgeError.deviceNotReady(
          "StikJIT returned an unknown readiness state."
        )
      }
      Armsx2NativeDiagnostic.append(
        "STATE: ARMSX2_SAFE_DEVICE_READY txm=\(securityState.isTXMPresent.map(String.init) ?? "unknown")"
      )

      // This is still the existing validated resolver: it discovers rewritten
      // sideload bundle identifiers through Installation Proxy and returns the
      // exact PID created by process_control.
      let runtime = try Armsx2IdeviceRuntime()
      let launch = try runtime.launchArmsx2Suspended(
        preferredBundleId: bundleIdHint,
        pairingFilePath: pairingFilePath,
        deviceAddress: configuration.deviceAddress,
        rsdPort: configuration.rsdPort
      )
      detectedBundleId = launch.bundleId
      targetPID = launch.pid
      Armsx2NativeDiagnostic.append(
        "STATE: ARMSX2_SAFE_SUSPENDED bundle=\(launch.bundleId) pid=\(launch.pid)"
      )

      preferenceGuard = try Armsx2AutoLoadPreferenceGuard()
      let guarded = try preferenceGuard!.temporarilyDisableIfEnabled(
        bundleId: launch.bundleId,
        pairingFilePath: pairingFilePath,
        deviceAddress: configuration.deviceAddress,
        rsdPort: configuration.rsdPort
      )
      preferenceState = guarded
      preferenceToken = guarded.token
      for line in guarded.logs {
        Armsx2NativeDiagnostic.append(line)
      }

      // If the user asked for Automatic Load but House Arrest could not locate
      // the preference, do not run the known-racy boot path. A visible launch
      // failure is safer than corrupting the emulator's CPU/ISO state.
      if guarded.detectedEnabled == nil && fallbackAutoLoad {
        throw Armsx2SafeBootError.autoLoadPreferenceUnavailable
      }

      // A second delayed restoration protects the user's setting if ARMSX2
      // crashes while universal.js is blocking inside enableJIT and this stack
      // never reaches its defer in time. Restoring the file does not change the
      // already-running process's cached preference; it only repairs the next
      // launch.
      if let token = guarded.token, let guardForFailsafe = preferenceGuard {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
          do {
            try guardForFailsafe.restore(
              token,
              pairingFilePath: pairingFilePath,
              deviceAddress: configuration.deviceAddress,
              rsdPort: configuration.rsdPort
            )
            Armsx2NativeDiagnostic.append(
              "STATE: ARMSX2_SAFE_AUTOLOAD_FAILSAFE_RESTORED"
            )
          } catch {
            Armsx2NativeDiagnostic.append(
              "STATE: ARMSX2_SAFE_AUTOLOAD_FAILSAFE_RESTORE_FAILED error=\(error.localizedDescription)"
            )
          }
        }
      }

      let handoff = Armsx2SafeURLHandoff()
      Armsx2NativeDiagnostic.append("STATE: ARMSX2_SAFE_BEFORE_ENABLE_JIT")

      if securityState.isTXMPresent == true {
        // The device is already prepared above. Use the no-DDI overload here so
        // there is no second preparation pass between suspended launch and
        // debugger attachment.
        try StikJIT.enableJIT(
          targetPID: launch.pid,
          pairingFile: pairingFile,
          configuration: configuration,
          script: .universal,
          forceScript: false
        ) { message in
          Armsx2NativeDiagnostic.append("JIT: \(message)")

          // universal.js logs attach_response before its first `c`. Blocking
          // this callback until UIKit accepts the URL guarantees the selected
          // ISO is queued while ARMSX2 is still held by debugserver, before the
          // PS2 CPU is allowed to run.
          if message.hasPrefix("attach_response =") && handoff.claimRequest() {
            Armsx2NativeDiagnostic.append(
              "STATE: ARMSX2_SAFE_SCRIPT_ATTACHED"
            )
            handoff.openSynchronously(gameURL)
          }
        }
      } else {
        // Without TXM the attach/detach itself enables JIT and there is no
        // universal breakpoint loop. AutoLoad is still suppressed, so wait for
        // attach/detach to finish, then deliver the selected game normally.
        try StikJIT.enableJIT(
          targetPID: launch.pid,
          pairingFile: pairingFile,
          configuration: configuration,
          script: .universal,
          forceScript: false
        ) { message in
          Armsx2NativeDiagnostic.append("JIT: \(message)")
        }
        if handoff.claimRequest() {
          handoff.openSynchronously(gameURL)
        }
      }

      Armsx2NativeDiagnostic.append("STATE: ARMSX2_SAFE_AFTER_ENABLE_JIT")

      guard handoff.opened == true else {
        if handoff.timedOut { throw Armsx2SafeBootError.gameURLTimeout }
        throw Armsx2SafeBootError.gameURLRejected
      }

      let effectiveAutoLoad =
        guarded.detectedEnabled ?? fallbackAutoLoad
      let response: [String: Any] = [
        "pid": Int(launch.pid),
        "bundleId": launch.bundleId,
        "txmPresent": securityState.isTXMPresent as Any,
        "jitReady": true,
        "gameUrlOpened": true,
        "postJitHandoffSkipped": false,
        "targetResumed": false,
        "detectedAutoLoadLastGame": guarded.detectedEnabled as Any,
        "effectiveAutoLoadLastGame": effectiveAutoLoad,
        "autoLoadModeSource": "safe_staged_url_during_jit",
        "detectedAutoLoadPreferenceKey": guarded.detectedKey as Any,
        "logs": [
          "STATE: ARMSX2_SAFE_BOOT_COMPLETE",
          "ARMSX2 bundle resolved as \(launch.bundleId).",
          "The selected game URL was queued while universal.js held the target before its first continue."
        ],
      ]

      DispatchQueue.main.async {
        backgroundTask.end()
        result(response)
      }
    } catch {
      Armsx2NativeDiagnostic.append(
        "STATE: ARMSX2_SAFE_ERROR bundle=\(detectedBundleId ?? "unknown") pid=\(targetPID.map(String.init) ?? "unknown") error=\(error.localizedDescription)"
      )
      DispatchQueue.main.async {
        backgroundTask.end()
        result(
          FlutterError(
            code: "stikjit_armsx2_safe_failed",
            message: error.localizedDescription,
            details: String(reflecting: error)
          )
        )
      }
    }
  }

  private static func preparationDescription(
    _ stage: StikJIT.PreparationStage
  ) -> String {
    switch stage {
    case .checkingReachability:
      return "checking reachability"
    case .checkingDDI:
      return "checking DDI"
    case .downloadingDDI(let fraction, let status):
      return "DDI download \(Int(fraction * 100))% \(status)"
    case .mountingDDI(let fraction):
      return "DDI mount \(Int(fraction * 100))%"
    case .verifyingDDI:
      return "verifying DDI"
    case .ready:
      return "ready"
    @unknown default:
      return "unknown"
    }
  }

  private static func appStateDescription() -> String {
    switch UIApplication.shared.applicationState {
    case .active: return "active"
    case .inactive: return "inactive"
    case .background: return "background"
    @unknown default: return "unknown"
    }
  }

  private static func finishError(
    _ error: Error,
    backgroundTask: Armsx2SafeBackgroundTask,
    result: @escaping FlutterResult
  ) {
    Armsx2NativeDiagnostic.append(
      "STATE: ARMSX2_SAFE_ERROR error=\(error.localizedDescription)"
    )
    DispatchQueue.main.async {
      backgroundTask.end()
      result(
        FlutterError(
          code: "stikjit_armsx2_safe_failed",
          message: error.localizedDescription,
          details: String(reflecting: error)
        )
      )
    }
  }
}

private final class Armsx2SafeURLHandoff {
  private let lock = NSLock()
  private var requested = false
  private(set) var opened: Bool?
  private(set) var timedOut = false

  func claimRequest() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !requested else { return false }
    requested = true
    return true
  }

  func openSynchronously(_ url: URL) {
    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.main.async {
      Armsx2NativeDiagnostic.append(
        "STATE: ARMSX2_SAFE_GAME_URL_REQUESTED neostationState=\(StikjitArmsx2SafeBridgePluginState.describe()) url=\(url.absoluteString)"
      )
      UIApplication.shared.open(url, options: [:]) { opened in
        self.lock.lock()
        self.opened = opened
        self.lock.unlock()
        Armsx2NativeDiagnostic.append(
          opened
            ? "STATE: ARMSX2_SAFE_GAME_URL_OPENED"
            : "STATE: ARMSX2_SAFE_GAME_URL_REJECTED"
        )
        semaphore.signal()
      }
    }

    if semaphore.wait(timeout: .now() + 4) == .timedOut {
      lock.lock()
      timedOut = true
      lock.unlock()
      Armsx2NativeDiagnostic.append(
        "STATE: ARMSX2_SAFE_GAME_URL_TIMEOUT"
      )
    }
  }
}

private enum StikjitArmsx2SafeBridgePluginState {
  static func describe() -> String {
    switch UIApplication.shared.applicationState {
    case .active: return "active"
    case .inactive: return "inactive"
    case .background: return "background"
    @unknown default: return "unknown"
    }
  }
}

private enum Armsx2NativeDiagnostic {
  private static let lock = NSLock()

  static func append(_ message: String) {
    lock.lock()
    defer { lock.unlock() }

    do {
      let documents = try FileManager.default.url(
        for: .documentDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let fileURL = documents.appendingPathComponent(
        "stikjit_armsx2_debug.txt"
      )
      let line = "[native \(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
      let data = Data(line.utf8)

      if !FileManager.default.fileExists(atPath: fileURL.path) {
        try data.write(to: fileURL, options: .atomic)
        return
      }

      let handle = try FileHandle(forWritingTo: fileURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } catch {
      // Diagnostics must never block JIT.
    }
  }
}

private final class Armsx2SafeBackgroundTask {
  private var identifier: UIBackgroundTaskIdentifier = .invalid

  init(name: String) {
    identifier = UIApplication.shared.beginBackgroundTask(
      withName: name
    ) { [weak self] in
      self?.end()
    }
  }

  func end() {
    guard identifier != .invalid else { return }
    let current = identifier
    identifier = .invalid
    UIApplication.shared.endBackgroundTask(current)
  }

  deinit { end() }
}
