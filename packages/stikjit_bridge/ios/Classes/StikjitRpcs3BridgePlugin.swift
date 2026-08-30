import Flutter
import Foundation
import StikJIT
import UIKit

/// Independent StikJIT path for RPCS3.
///
/// RPCS3 has no supported direct-game URL in the current iOS port. This bridge
/// therefore launches the detected RPCS3 app suspended, enables JIT on that
/// exact PID, and lets the universal script resume/foreground RPCS3. The native
/// RPCS3 Start/game-selection screen remains unchanged.
public final class StikjitRpcs3BridgePlugin: NSObject, FlutterPlugin {
  private static let channelName = "neostation/stikjit_rpcs3"
  private static let jitQueue = DispatchQueue(
    label: "com.neogamelab.neostation.stikjit.rpcs3",
    qos: .userInitiated
  )

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(
      StikjitRpcs3BridgePlugin(),
      channel: channel
    )
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "enableRpcs3Jit" else {
      result(FlutterMethodNotImplemented)
      return
    }

    guard #available(iOS 17.4, *) else {
      result(
        FlutterError(
          code: "stikjit_rpcs3_unsupported_ios",
          message: "Built-in StikJIT for RPCS3 requires iOS 17.4 or newer.",
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
      !bundleIdHint.isEmpty
    else {
      result(
        FlutterError(
          code: "stikjit_rpcs3_invalid_arguments",
          message: "A pairing file and RPCS3 bundle identifier hint are required.",
          details: nil
        )
      )
      return
    }

    let titleId = (arguments["titleId"] as? String)?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ) ?? ""
    let backgroundTask = Rpcs3StikJitBackgroundTask(
      name: "RPCS3 integrated JIT"
    )

    Self.jitQueue.async {
      do {
        let response = try Self.enableRpcs3Jit(
          pairingFilePath: pairingFilePath,
          bundleIdHint: bundleIdHint,
          titleId: titleId
        )
        DispatchQueue.main.async {
          backgroundTask.end()
          result(response)
        }
      } catch {
        DispatchQueue.main.async {
          backgroundTask.end()
          result(
            FlutterError(
              code: "stikjit_rpcs3_enable_failed",
              message: error.localizedDescription,
              details: String(reflecting: error)
            )
          )
        }
      }
    }
  }

  @available(iOS 17.4, *)
  private static func enableRpcs3Jit(
    pairingFilePath: String,
    bundleIdHint: String,
    titleId: String
  ) throws -> [String: Any] {
    let pairingFile = URL(fileURLWithPath: pairingFilePath)
    guard FileManager.default.isReadableFile(atPath: pairingFile.path) else {
      throw Rpcs3BridgeError.pairingFileMissing
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
      "Preparing LocalDevVPN/RSD endpoint and Developer Disk Image for RPCS3."
    )
    if !titleId.isEmpty {
      logs.append(
        "Requested NeoStation title ID: \(titleId). RPCS3 currently performs native game selection."
      )
    }

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
      throw Rpcs3BridgeError.deviceNotReady(reason)
    case .preparationFailed(let reason):
      throw Rpcs3BridgeError.deviceNotReady(reason)
    @unknown default:
      throw Rpcs3BridgeError.deviceNotReady(
        "StikJIT returned an unknown device-readiness state."
      )
    }

    let runtime = try Rpcs3IdeviceRuntime()
    let launch = try runtime.launchRpcs3Suspended(
      preferredBundleId: bundleIdHint,
      pairingFilePath: pairingFile.path,
      deviceAddress: configuration.deviceAddress,
      rsdPort: configuration.rsdPort
    )
    logs.append("Detected RPCS3 bundle ID: \(launch.bundleId).")
    logs.append("RPCS3 launched suspended with PID \(launch.pid).")

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
    logs.append("STATE: RPCS3_JIT_READY")
    logs.append(
      "StikJIT completed and detached from RPCS3; RPCS3 remains responsible for its native Start/game-selection screen."
    )

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
}

private final class Rpcs3StikJitBackgroundTask {
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

enum Rpcs3BridgeError: LocalizedError {
  case pairingFileMissing
  case deviceNotReady(String)
  case symbolMissing(String)
  case invalidDeviceAddress(String)
  case idevice(String)
  case incompleteHandle(String)
  case rpcs3NotFound(String)

  var errorDescription: String? {
    switch self {
    case .pairingFileMissing:
      return "The selected pairing file is no longer readable."
    case .deviceNotReady(let reason):
      return "StikJIT device preparation failed for RPCS3: \(reason)"
    case .symbolMissing(let symbol):
      return "StikJIT framework is missing required RPCS3 symbol \(symbol)."
    case .invalidDeviceAddress(let address):
      return "Invalid LocalDevVPN device address: \(address)"
    case .idevice(let message):
      return message
    case .incompleteHandle(let name):
      return "RPCS3 StikJIT runtime did not create \(name)."
    case .rpcs3NotFound(let hint):
      return "RPCS3 was not found through Installation Proxy. Bundle hint: \(hint)."
    }
  }
}
