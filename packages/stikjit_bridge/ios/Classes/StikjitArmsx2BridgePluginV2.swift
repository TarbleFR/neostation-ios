import Darwin
import Flutter
import Foundation
import StikJIT
import UIKit

/// Second-generation ARMSX2 bridge.
///
/// ARMSX2 is launched suspended and receives JIT on that exact PID. In
/// Automatic Load Last Game mode the target itself eventually executes the
/// universal JIT detach command. Once StikJIT returns, the debugger has already
/// detached from the original ARMSX2 PID, so NeoStation must not add another
/// process-control resume or URL activation on top of that transition.
///
/// Automatic-load path:
/// 1. launch ARMSX2 suspended;
/// 2. enable JIT on that PID;
/// 3. universal.js handles JIT26Detach / debugger `D`;
/// 4. detect the persisted Automatic Load Last Game preference;
/// 5. if enabled, end the NeoStation background task and do nothing else.
///
/// Legacy mode (Automatic Load disabled) retains the explicit game-URL handoff.
public final class StikjitArmsx2BridgePluginV2: NSObject, FlutterPlugin {
  private static let channelName = "neostation/stikjit_armsx2"
  private static let jitQueue = DispatchQueue(
    label: "com.neogamelab.neostation.stikjit.armsx2.v2",
    qos: .userInitiated
  )
  private static let handoffQueue = DispatchQueue(
    label: "com.neogamelab.neostation.stikjit.armsx2.v2.handoff",
    qos: .userInitiated
  )

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(
      StikjitArmsx2BridgePluginV2(),
      channel: channel
    )
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "enableArmsx2Jit" else {
      result(FlutterMethodNotImplemented)
      return
    }

    guard #available(iOS 17.4, *) else {
      result(
        FlutterError(
          code: "stikjit_armsx2_unsupported_ios",
          message: "Built-in StikJIT for ARMSX2 requires iOS 17.4 or newer.",
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
      let gameUrlString = arguments["gameUrl"] as? String,
      !gameUrlString.isEmpty,
      let gameUrl = URL(string: gameUrlString),
      gameUrl.scheme?.lowercased() == "armsx2"
    else {
      result(
        FlutterError(
          code: "stikjit_armsx2_invalid_arguments",
          message: "A pairing file, ARMSX2 bundle hint, and armsx2:// game URL are required.",
          details: nil
        )
      )
      return
    }

    let fallbackAutoLoadLastGame =
      arguments["autoLoadLastGame"] as? Bool ?? false
    let backgroundTask = Armsx2LifecycleBackgroundTask(
      name: "ARMSX2 JIT lifecycle handoff"
    )

    Self.jitQueue.async {
      do {
        var response = try Self.enableArmsx2Jit(
          pairingFilePath: pairingFilePath,
          bundleIdHint: bundleIdHint
        )
        var logs = response["logs"] as? [String] ?? []

        let detectedAutoLoad = response["detectedAutoLoadLastGame"] as? Bool
        let effectiveAutoLoad = detectedAutoLoad ?? fallbackAutoLoadLastGame
        response["effectiveAutoLoadLastGame"] = effectiveAutoLoad
        response["autoLoadModeSource"] = detectedAutoLoad == nil
          ? "neostation_fallback"
          : "armsx2_preferences"

        logs.append("STATE: ARMSX2_V2_JIT_PID_READY")
        if let detectedAutoLoad {
          logs.append("STATE: ARMSX2_V2_AUTOLOAD_DETECTED")
          logs.append(
            "ARMSX2 Automatic Load Last Game detected as \(detectedAutoLoad)."
          )
        } else {
          logs.append("STATE: ARMSX2_V2_AUTOLOAD_FALLBACK")
          logs.append(
            "ARMSX2 preference unavailable; using NeoStation fallback \(fallbackAutoLoadLastGame)."
          )
        }
        response["logs"] = logs

        if effectiveAutoLoad {
          // StikJIT's universal script leaves its loop only after the target
          // requests JIT26Detach(), whose handler sends debugger command `D`.
          // StikJIT.enableJIT therefore returns only after the original ARMSX2
          // PID has been detached and allowed to continue. Do not perturb that
          // normal transition with another process_control or UIApplication URL.
          var completed = response
          var completedLogs = completed["logs"] as? [String] ?? []
          completed["postJitHandoffSkipped"] = true
          completed["gameUrlOpened"] = false
          completed["targetResumed"] = true
          completed["neutralActivationOpened"] = false
          completed["resumeStrategy"] = "stikjit_detach_only"
          completedLogs.append("STATE: ARMSX2_V2_DETACH_ONLY")
          completedLogs.append(
            "Automatic Load is enabled. StikJIT already detached from the JIT-enabled ARMSX2 PID; NeoStation performs no post-JIT process-control resume and opens no second ARMSX2 URL."
          )
          completed["logs"] = completedLogs

          DispatchQueue.main.async {
            backgroundTask.end()
            result(completed)
          }
          return
        }

        // Automatic Load is disabled: keep the explicit game-specific URL
        // handoff that the frontend requires in this mode.
        self.performLifecycleHandoff(
          targetURL: gameUrl,
          automaticLoad: false,
          response: response,
          pairingFilePath: pairingFilePath,
          backgroundTask: backgroundTask,
          result: result
        )
      } catch {
        DispatchQueue.main.async {
          backgroundTask.end()
          result(
            FlutterError(
              code: "stikjit_armsx2_enable_failed",
              message: error.localizedDescription,
              details: String(reflecting: error)
            )
          )
        }
      }
    }
  }

  @available(iOS 17.4, *)
  private static func enableArmsx2Jit(
    pairingFilePath: String,
    bundleIdHint: String
  ) throws -> [String: Any] {
    let pairingFile = URL(fileURLWithPath: pairingFilePath)
    guard FileManager.default.isReadableFile(atPath: pairingFile.path) else {
      throw Armsx2LifecycleError.pairingFileMissing
    }

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

    let configuration = StikJIT.Configuration.default
    let ddiPaths = DDIPaths.default(in: stikRoot)
    var logs = [String]()

    // The public enableJIT(...ddiPaths...) API already performs device
    // preparation. Keep a single preparation pass.
    logs.append("STATE: ARMSX2_V2_SINGLE_PREPARE_PATH")

    let runtime = try Armsx2IdeviceRuntime()
    let launch = try runtime.launchArmsx2Suspended(
      preferredBundleId: bundleIdHint,
      pairingFilePath: pairingFile.path,
      deviceAddress: configuration.deviceAddress,
      rsdPort: configuration.rsdPort
    )
    logs.append("Detected ARMSX2 bundle ID: \(launch.bundleId).")
    logs.append("ARMSX2 launched suspended with PID \(launch.pid).")

    try StikJIT.enableJIT(
      targetPID: launch.pid,
      pairingFile: pairingFile,
      ddiPaths: ddiPaths,
      configuration: configuration,
      script: .universal,
      forceScript: false,
      preparationProgress: { stage in
        logs.append(Self.preparationDescription(stage))
      },
      progress: { message in
        logs.append(message)
      }
    )
    logs.append("StikJIT completed and detached from ARMSX2.")

    var detectedAutoLoadLastGame: Bool?
    var detectedPreferenceKey: String?
    do {
      let detection = try Armsx2PreferenceDetector().detect(
        bundleId: launch.bundleId,
        pairingFilePath: pairingFile.path,
        deviceAddress: configuration.deviceAddress,
        rsdPort: configuration.rsdPort
      )
      detectedAutoLoadLastGame = detection.enabled
      detectedPreferenceKey = detection.key
      logs.append(contentsOf: detection.logs)
    } catch {
      logs.append("STATE: ARMSX2_V2_AUTOLOAD_PREFERENCE_DETECTION_FAILED")
      logs.append(
        "Automatic Load Last Game preference detection failed safely: \(error.localizedDescription)"
      )
    }

    var response: [String: Any] = [
      "pid": Int(launch.pid),
      "bundleId": launch.bundleId,
      "logs": logs,
    ]
    if let txmPresent = StikJIT.isTXMPresent {
      response["txmPresent"] = txmPresent
    }
    if let detectedAutoLoadLastGame {
      response["detectedAutoLoadLastGame"] = detectedAutoLoadLastGame
    }
    if let detectedPreferenceKey {
      response["detectedAutoLoadPreferenceKey"] = detectedPreferenceKey
    }
    return response
  }

  @available(iOS 17.4, *)
  private func performLifecycleHandoff(
    targetURL: URL,
    automaticLoad: Bool,
    response: [String: Any],
    pairingFilePath: String,
    backgroundTask: Armsx2LifecycleBackgroundTask,
    result: @escaping FlutterResult
  ) {
    guard let neoStationBundleId = Bundle.main.bundleIdentifier,
          !neoStationBundleId.isEmpty else {
      var failed = response
      var logs = failed["logs"] as? [String] ?? []
      logs.append("STATE: ARMSX2_V2_NEOSTATION_BUNDLE_ID_MISSING")
      failed["logs"] = logs
      DispatchQueue.main.async {
        backgroundTask.end()
        result(failed)
      }
      return
    }

    Self.handoffQueue.async {
      do {
        let configuration = StikJIT.Configuration.default
        let activatedPID = try Armsx2NeoStationProcessActivator().activate(
          bundleId: neoStationBundleId,
          pairingFilePath: pairingFilePath,
          deviceAddress: configuration.deviceAddress,
          rsdPort: configuration.rsdPort
        )

        var activated = response
        var logs = activated["logs"] as? [String] ?? []
        activated["neoStationPid"] = Int(activatedPID)
        activated["neoStationLocalPid"] = Int(getpid())
        logs.append("STATE: ARMSX2_V2_NEOSTATION_FOREGROUND_REQUESTED")
        logs.append(
          "process_control returned NeoStation PID \(activatedPID); local PID is \(getpid())."
        )
        if activatedPID == UInt64(getpid()) {
          logs.append("STATE: ARMSX2_V2_NEOSTATION_SAME_PID_CONFIRMED")
        } else {
          logs.append("STATE: ARMSX2_V2_NEOSTATION_PID_MISMATCH")
        }
        activated["logs"] = logs

        DispatchQueue.main.async {
          self.openTargetWhenNeoStationIsActive(
            targetURL,
            automaticLoad: automaticLoad,
            response: activated,
            backgroundTask: backgroundTask,
            result: result
          )
        }
      } catch {
        var failed = response
        var logs = failed["logs"] as? [String] ?? []
        logs.append("STATE: ARMSX2_V2_NEOSTATION_FOREGROUND_FAILED")
        logs.append(
          "NeoStation foreground re-acquisition failed: \(error.localizedDescription)"
        )
        failed["logs"] = logs
        DispatchQueue.main.async {
          backgroundTask.end()
          result(failed)
        }
      }
    }
  }

  private func openTargetWhenNeoStationIsActive(
    _ targetURL: URL,
    automaticLoad: Bool,
    response: [String: Any],
    backgroundTask: Armsx2LifecycleBackgroundTask,
    result: @escaping FlutterResult
  ) {
    var attempts = 0
    let maximumAttempts = 40

    func attemptOpen() {
      attempts += 1
      guard UIApplication.shared.applicationState == .active else {
        if attempts < maximumAttempts {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            attemptOpen()
          }
          return
        }

        var failed = response
        var logs = failed["logs"] as? [String] ?? []
        logs.append("STATE: ARMSX2_V2_NEOSTATION_ACTIVE_TIMEOUT")
        failed["logs"] = logs
        failed["postJitHandoffSkipped"] = automaticLoad
        failed["targetResumed"] = false
        failed["gameUrlOpened"] = false
        backgroundTask.end()
        result(failed)
        return
      }

      var opening = response
      var logs = opening["logs"] as? [String] ?? []
      logs.append("STATE: ARMSX2_V2_NEOSTATION_ACTIVE")
      logs.append("Opening ARMSX2 URL from active NeoStation: \(targetURL.absoluteString)")
      opening["logs"] = logs

      UIApplication.shared.open(targetURL, options: [:]) { opened in
        var completed = opening
        var completedLogs = completed["logs"] as? [String] ?? []

        if automaticLoad {
          completed["postJitHandoffSkipped"] = true
          completed["gameUrlOpened"] = false
          completed["targetResumed"] = opened
          completed["neutralActivationOpened"] = opened
          completed["resumeStrategy"] = "neostation_active_then_neutral_url"
          completedLogs.append(
            opened
              ? "STATE: ARMSX2_V2_NEUTRAL_ACTIVATION_ACCEPTED"
              : "STATE: ARMSX2_V2_NEUTRAL_ACTIVATION_REJECTED"
          )
        } else {
          completed["postJitHandoffSkipped"] = false
          completed["gameUrlOpened"] = opened
          completed["targetResumed"] = false
          completed["resumeStrategy"] = "neostation_active_then_game_url"
          completedLogs.append(
            opened
              ? "STATE: ARMSX2_V2_GAME_URL_ACCEPTED"
              : "STATE: ARMSX2_V2_GAME_URL_REJECTED"
          )
        }

        completed["logs"] = completedLogs
        backgroundTask.end()
        result(completed)
      }
    }

    attemptOpen()
  }

  private static func preparationDescription(
    _ stage: StikJIT.PreparationStage
  ) -> String {
    switch stage {
    case .checkingReachability:
      return "Checking LocalDevVPN/RSD reachability."
    case .checkingDDI:
      return "Checking Developer Disk Image."
    case .downloadingDDI(let fraction, let status):
      return "DDI download \(Int(fraction * 100))%: \(status)"
    case .mountingDDI(let fraction):
      return "Mounting DDI: \(Int(fraction * 100))%"
    case .verifyingDDI:
      return "Verifying mounted DDI."
    case .ready:
      return "Device is ready for JIT."
    @unknown default:
      return "StikJIT reported an unknown preparation stage."
    }
  }
}

private final class Armsx2LifecycleBackgroundTask {
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
    let value = identifier
    identifier = .invalid
    UIApplication.shared.endBackgroundTask(value)
  }

  deinit {
    end()
  }
}

private enum Armsx2LifecycleError: LocalizedError {
  case pairingFileMissing

  var errorDescription: String? {
    switch self {
    case .pairingFileMissing:
      return "The selected pairing file is no longer readable."
    }
  }
}
