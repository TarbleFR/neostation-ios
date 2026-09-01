import Darwin
import Flutter
import Foundation
import StikJIT
import UIKit

/// Composite registration keeps the validated MeloNX bridge untouched and
/// adds ARMSX2 on a completely separate method channel.
public final class NeoStationStikjitBridgePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    StikjitBridgePluginV2.register(with: registrar)
    StikjitArmsx2BridgePlugin.register(with: registrar)
  }
}

/// Independent StikJIT path for ARMSX2.
///
/// This class deliberately does not route through, subclass, or modify the
/// MeloNX bridge. It launches the detected ARMSX2 process suspended and enables
/// JIT on that exact PID. The legacy mode then brings NeoStation back to the
/// foreground and delivers the selected ARMSX2 URL. The optional automatic-load
/// mode stops immediately after JIT so ARMSX2 can continue through its own
/// "Automatic Load Last Game" startup without being opened a second time.
public final class StikjitArmsx2BridgePlugin: NSObject, FlutterPlugin {
  private static let channelName = "neostation/stikjit_armsx2"
  private static let jitQueue = DispatchQueue(
    label: "com.neogamelab.neostation.stikjit.armsx2",
    qos: .userInitiated
  )
  private static let handoffQueue = DispatchQueue(
    label: "com.neogamelab.neostation.stikjit.armsx2.handoff",
    qos: .userInitiated
  )

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(
      StikjitArmsx2BridgePlugin(),
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
          message: "A pairing file, ARMSX2 bundle identifier hint, and valid armsx2:// game URL are required.",
          details: nil
        )
      )
      return
    }

    let autoLoadLastGame = arguments["autoLoadLastGame"] as? Bool ?? false
    let backgroundTask = Armsx2StikJitBackgroundTask(
      name: autoLoadLastGame
        ? "ARMSX2 automatic-load JIT"
        : "ARMSX2 post-JIT handoff"
    )

    Self.jitQueue.async {
      do {
        var response = try Self.enableArmsx2Jit(
          pairingFilePath: pairingFilePath,
          bundleIdHint: bundleIdHint
        )
        var logs = response["logs"] as? [String] ?? []
        logs.append("STATE: ARMSX2_JIT_PID_READY")

        if autoLoadLastGame {
          logs.append("STATE: ARMSX2_AUTOLOAD_HANDOFF_SKIPPED")
          logs.append(
            "ARMSX2 Automatic Load Last Game mode is enabled. NeoStation will not reclaim the foreground or send the game URL a second time."
          )
          response["logs"] = logs
          response["postJitHandoffSkipped"] = true
          response["gameUrlOpened"] = false

          DispatchQueue.main.async {
            backgroundTask.end()
            result(response)
          }
          return
        }

        logs.append(
          "JIT detached. Re-acquiring NeoStation foreground before delivering the ARMSX2 game URL."
        )
        response["logs"] = logs
        response["postJitHandoffSkipped"] = false

        guard let neoStationBundleId = Bundle.main.bundleIdentifier,
              !neoStationBundleId.isEmpty else {
          var failed = response
          var failedLogs = failed["logs"] as? [String] ?? []
          failedLogs.append("STATE: NEOSTATION_BUNDLE_ID_MISSING")
          failed["logs"] = failedLogs
          failed["gameUrlOpened"] = false
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
            var activatedLogs = activated["logs"] as? [String] ?? []
            activated["neoStationPid"] = Int(activatedPID)
            activatedLogs.append("STATE: NEOSTATION_FOREGROUND_REQUESTED")
            activatedLogs.append(
              "process_control returned NeoStation PID \(activatedPID); local PID is \(getpid())."
            )
            if activatedPID == UInt64(getpid()) {
              activatedLogs.append("STATE: NEOSTATION_SAME_PID_CONFIRMED")
            } else {
              activatedLogs.append(
                "WARNING: process_control reported a different NeoStation PID. Continuing only if the current process becomes active."
              )
            }
            activated["logs"] = activatedLogs

            DispatchQueue.main.async {
              self.openGameWhenNeoStationIsActive(
                gameUrl,
                response: activated,
                backgroundTask: backgroundTask,
                result: result
              )
            }
          } catch {
            var failed = response
            var failedLogs = failed["logs"] as? [String] ?? []
            failedLogs.append("STATE: NEOSTATION_FOREGROUND_FAILED")
            failedLogs.append(
              "NeoStation foreground re-acquisition failed: \(error.localizedDescription)"
            )
            failed["logs"] = failedLogs
            failed["gameUrlOpened"] = false

            DispatchQueue.main.async {
              backgroundTask.end()
              result(failed)
            }
          }
        }
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
      throw Armsx2BridgeError.pairingFileMissing
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

    logs.append(
      "Preparing LocalDevVPN/RSD endpoint and Developer Disk Image for ARMSX2."
    )
    let readiness = StikJIT.prepareDevice(
      pairingFile: pairingFile,
      paths: ddiPaths,
      configuration: configuration
    ) { stage in
      logs.append(Self.preparationDescription(stage))
    }

    let securityState: StikJIT.DeviceSecurityState
    switch readiness {
    case .ready(let state):
      securityState = state
    case .unreachable(let reason):
      throw Armsx2BridgeError.deviceNotReady(reason)
    case .preparationFailed(let reason):
      throw Armsx2BridgeError.deviceNotReady(reason)
    @unknown default:
      throw Armsx2BridgeError.deviceNotReady(
        "StikJIT returned an unknown device-readiness state."
      )
    }

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

    var response: [String: Any] = [
      "pid": Int(launch.pid),
      "bundleId": launch.bundleId,
      "logs": logs,
    ]
    if let txmPresent = securityState.isTXMPresent {
      response["txmPresent"] = txmPresent
    }
    return response
  }

  @available(iOS 17.4, *)
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

  private func openGameWhenNeoStationIsActive(
    _ gameUrl: URL,
    response: [String: Any],
    backgroundTask: Armsx2StikJitBackgroundTask,
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
        var failedLogs = failed["logs"] as? [String] ?? []
        failedLogs.append("STATE: NEOSTATION_ACTIVE_TIMEOUT")
        failedLogs.append(
          "NeoStation did not become active within 4 seconds, so the ARMSX2 game URL was not sent from the background."
        )
        failed["logs"] = failedLogs
        failed["gameUrlOpened"] = false
        backgroundTask.end()
        result(failed)
        return
      }

      var opening = response
      var openingLogs = opening["logs"] as? [String] ?? []
      openingLogs.append("STATE: NEOSTATION_ACTIVE")
      openingLogs.append("Post-JIT ARMSX2 URL: \(gameUrl.absoluteString)")
      openingLogs.append(
        "Opening the ARMSX2 game URL from active NeoStation; the already-JITed ARMSX2 process must receive this request."
      )
      opening["logs"] = openingLogs

      UIApplication.shared.open(gameUrl, options: [:]) { opened in
        var completed = opening
        var completedLogs = completed["logs"] as? [String] ?? []
        completed["gameUrlOpened"] = opened
        if opened {
          completedLogs.append("STATE: ARMSX2_GAME_URL_POST_JIT_OPENED")
          completedLogs.append(
            "UIApplication.open accepted the ARMSX2 game URL after NeoStation foreground re-acquisition."
          )
        } else {
          completedLogs.append("STATE: ARMSX2_GAME_URL_POST_JIT_OPEN_FAILED")
          completedLogs.append(
            "UIApplication.open rejected the ARMSX2 game URL even though NeoStation was active."
          )
        }
        completed["logs"] = completedLogs
        backgroundTask.end()
        result(completed)
      }
    }

    attemptOpen()
  }
}

private final class Armsx2StikJitBackgroundTask {
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

enum Armsx2BridgeError: LocalizedError {
  case pairingFileMissing
  case deviceNotReady(String)
  case symbolMissing(String)
  case invalidDeviceAddress(String)
  case idevice(String)
  case incompleteHandle(String)
  case armsx2NotFound(String)

  var errorDescription: String? {
    switch self {
    case .pairingFileMissing:
      return "The selected pairing file is no longer readable."
    case .deviceNotReady(let reason):
      return "StikJIT device preparation failed for ARMSX2: \(reason)"
    case .symbolMissing(let symbol):
      return "StikJIT framework is missing required ARMSX2 symbol \(symbol)."
    case .invalidDeviceAddress(let address):
      return "Invalid LocalDevVPN device address: \(address)"
    case .idevice(let message):
      return message
    case .incompleteHandle(let name):
      return "ARMSX2 StikJIT runtime did not create \(name)."
    case .armsx2NotFound(let hint):
      return "ARMSX2 was not found through Installation Proxy. Bundle hint: \(hint)."
    }
  }
}
