import Darwin
import Flutter
import Foundation
import StikJIT
import UIKit

/// Direct post-JIT handoff for MeloNX without Shortcuts or StikDebug.
///
/// StikJIT launches MeloNX suspended and enables JIT on that exact PID. The
/// universal script detaches when MeloNX is ready, which can make MeloNX the
/// foreground app before NeoStation gets a chance to open the frontend URL.
/// UIApplication.open is unreliable from a backgrounded NeoStation, so this
/// bridge deliberately brings the *existing* NeoStation process back to the
/// foreground through process_control_launch_app(suspended=false,
/// terminateExisting=false), waits for UIApplicationState.active, then sends
/// the MeloNX game URL. No MeloNX process is terminated or relaunched.
public final class StikjitBridgePluginV2: NSObject, FlutterPlugin {
  private static let handoffQueue = DispatchQueue(
    label: "com.neogamelab.neostation.stikjit.handoff",
    qos: .userInitiated
  )

  private let legacy = StikjitBridgePlugin()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "neostation/stikjit",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(StikjitBridgePluginV2(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "enableMeloNxJit" else {
      legacy.handle(call, result: result)
      return
    }

    guard
      let arguments = call.arguments as? [String: Any],
      let pairingFilePath = arguments["pairingFilePath"] as? String,
      !pairingFilePath.isEmpty,
      let gameUrlString = arguments["gameUrl"] as? String,
      let gameUrl = URL(string: gameUrlString),
      !gameUrlString.isEmpty
    else {
      result(
        FlutterError(
          code: "stikjit_invalid_game_url",
          message: "A pairing file and valid MeloNX game URL are required for the direct handoff.",
          details: nil
        )
      )
      return
    }

    let backgroundTask = StikJitBackgroundTask(name: "MeloNX post-JIT handoff")

    legacy.handle(call) { value in
      guard #available(iOS 17.4, *) else {
        backgroundTask.end()
        result(value)
        return
      }

      guard var response = value as? [String: Any] else {
        backgroundTask.end()
        result(value)
        return
      }

      var logs = response["logs"] as? [String] ?? []
      logs.append("STATE: JIT_PID_READY")
      if let pid = Self.intValue(response["pid"]) {
        logs.append("MeloNX JIT PID retained: \(pid).")
      }
      logs.append(
        "JIT detached. Re-acquiring NeoStation foreground before delivering the MeloNX frontend URL."
      )
      response["logs"] = logs

      guard let neoStationBundleId = Bundle.main.bundleIdentifier,
            !neoStationBundleId.isEmpty else {
        var failed = response
        var failedLogs = failed["logs"] as? [String] ?? []
        failedLogs.append("STATE: NEOSTATION_BUNDLE_ID_MISSING")
        failed["logs"] = failedLogs
        failed["gameUrlOpened"] = false
        backgroundTask.end()
        result(failed)
        return
      }

      Self.handoffQueue.async {
        do {
          let configuration = StikJIT.Configuration.default
          let activatedPID = try NeoStationProcessActivator().activate(
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
          failedLogs.append("NeoStation foreground re-acquisition failed: \(error.localizedDescription)")
          failed["logs"] = failedLogs
          failed["gameUrlOpened"] = false

          DispatchQueue.main.async {
            backgroundTask.end()
            result(failed)
          }
        }
      }
    }
  }

  private func openGameWhenNeoStationIsActive(
    _ gameUrl: URL,
    response: [String: Any],
    backgroundTask: StikJitBackgroundTask,
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
          "NeoStation did not become active within 4 seconds, so the game URL was not sent from the background."
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
      openingLogs.append("Post-JIT URL: \(gameUrl.absoluteString)")
      openingLogs.append(
        "Opening MeloNX frontend URL from active NeoStation; the already-JITed MeloNX process must receive this request."
      )
      opening["logs"] = openingLogs

      UIApplication.shared.open(gameUrl, options: [:]) { opened in
        var completed = opening
        var completedLogs = completed["logs"] as? [String] ?? []
        completed["gameUrlOpened"] = opened
        if opened {
          completedLogs.append("STATE: GAME_URL_POST_JIT_OPENED")
          completedLogs.append(
            "UIApplication.open accepted the MeloNX frontend URL after NeoStation foreground re-acquisition."
          )
        } else {
          completedLogs.append("STATE: GAME_URL_POST_JIT_OPEN_FAILED")
          completedLogs.append(
            "UIApplication.open rejected the MeloNX frontend URL even though NeoStation was active."
          )
        }
        completed["logs"] = completedLogs
        backgroundTask.end()
        result(completed)
      }
    }

    attemptOpen()
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return nil
  }
}

/// Keeps NeoStation executing for the short interval where StikJIT's detach can
/// foreground MeloNX before process-control returns NeoStation to the front.
private final class StikJitBackgroundTask {
  private var identifier: UIBackgroundTaskIdentifier = .invalid

  init(name: String) {
    identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
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

private struct HandoffIdeviceErrorRecord {
  let code: Int32
  let subCode: Int32
  let message: UnsafePointer<CChar>?
}

private enum NeoStationActivationError: LocalizedError {
  case pairingFileMissing
  case invalidDeviceAddress(String)
  case symbolMissing(String)
  case incompleteHandle(String)
  case idevice(String)

  var errorDescription: String? {
    switch self {
    case .pairingFileMissing:
      return "The pairing file is no longer readable during the post-JIT handoff."
    case .invalidDeviceAddress(let address):
      return "Invalid LocalDevVPN device address during handoff: \(address)"
    case .symbolMissing(let symbol):
      return "StikJIT framework is missing required handoff symbol \(symbol)."
    case .incompleteHandle(let name):
      return "The post-JIT handoff did not create \(name)."
    case .idevice(let message):
      return message
    }
  }
}

/// Minimal process-control client used only to bring the existing NeoStation
/// process back to the foreground. The important flags mirror StikDebug's
/// `relaunchApp`: suspended=false, terminateExisting=false.
@available(iOS 17.4, *)
private final class NeoStationProcessActivator {
  private typealias PinCallback = @convention(c) (
    UnsafeMutableRawPointer?
  ) -> UnsafePointer<CChar>?

  private typealias PairingReadFn = @convention(c) (
    UnsafePointer<CChar>?,
    UnsafeMutablePointer<OpaquePointer?>?
  ) -> OpaquePointer?
  private typealias PairingFreeFn = @convention(c) (OpaquePointer?) -> Void
  private typealias TunnelCreateFn = @convention(c) (
    UnsafePointer<sockaddr>?,
    socklen_t,
    UnsafePointer<CChar>?,
    OpaquePointer?,
    PinCallback?,
    UnsafeMutableRawPointer?,
    UnsafeMutablePointer<OpaquePointer?>?,
    UnsafeMutablePointer<OpaquePointer?>?
  ) -> OpaquePointer?
  private typealias AdapterFreeFn = @convention(c) (OpaquePointer?) -> Void
  private typealias HandshakeFreeFn = @convention(c) (OpaquePointer?) -> Void
  private typealias RemoteConnectFn = @convention(c) (
    OpaquePointer?,
    OpaquePointer?,
    UnsafeMutablePointer<OpaquePointer?>?
  ) -> OpaquePointer?
  private typealias RemoteFreeFn = @convention(c) (OpaquePointer?) -> Void
  private typealias ProcessNewFn = @convention(c) (
    OpaquePointer?,
    UnsafeMutablePointer<OpaquePointer?>?
  ) -> OpaquePointer?
  private typealias ProcessFreeFn = @convention(c) (OpaquePointer?) -> Void
  private typealias LaunchAppFn = @convention(c) (
    OpaquePointer?,
    UnsafePointer<CChar>?,
    UnsafePointer<UnsafePointer<CChar>?>?,
    UInt,
    UnsafePointer<UnsafePointer<CChar>?>?,
    UInt,
    Bool,
    Bool,
    UnsafeMutablePointer<UInt64>?
  ) -> OpaquePointer?
  private typealias ErrorFreeFn = @convention(c) (OpaquePointer?) -> Void

  private let handles: [UnsafeMutableRawPointer]
  private let pairingRead: PairingReadFn
  private let pairingFree: PairingFreeFn
  private let tunnelCreate: TunnelCreateFn
  private let adapterFree: AdapterFreeFn
  private let handshakeFree: HandshakeFreeFn
  private let remoteConnect: RemoteConnectFn
  private let remoteFree: RemoteFreeFn
  private let processNew: ProcessNewFn
  private let processFree: ProcessFreeFn
  private let launchApp: LaunchAppFn
  private let errorFree: ErrorFreeFn

  init() throws {
    _ = StikJIT.isTXMPresent

    var loadedHandles = [UnsafeMutableRawPointer]()
    if
      let frameworks = Bundle.main.privateFrameworksURL,
      let frameworkHandle = dlopen(
        frameworks.appendingPathComponent("StikJIT.framework/StikJIT").path,
        RTLD_NOW | RTLD_GLOBAL
      )
    {
      loadedHandles.append(frameworkHandle)
    }
    if let processHandle = dlopen(nil, RTLD_NOW) {
      loadedHandles.append(processHandle)
    }
    handles = loadedHandles

    pairingRead = try Self.resolve("rp_pairing_file_read", in: handles, as: PairingReadFn.self)
    pairingFree = try Self.resolve("rp_pairing_file_free", in: handles, as: PairingFreeFn.self)
    tunnelCreate = try Self.resolve("tunnel_create_rppairing", in: handles, as: TunnelCreateFn.self)
    adapterFree = try Self.resolve("adapter_free", in: handles, as: AdapterFreeFn.self)
    handshakeFree = try Self.resolve("rsd_handshake_free", in: handles, as: HandshakeFreeFn.self)
    remoteConnect = try Self.resolve("remote_server_connect_rsd", in: handles, as: RemoteConnectFn.self)
    remoteFree = try Self.resolve("remote_server_free", in: handles, as: RemoteFreeFn.self)
    processNew = try Self.resolve("process_control_new", in: handles, as: ProcessNewFn.self)
    processFree = try Self.resolve("process_control_free", in: handles, as: ProcessFreeFn.self)
    launchApp = try Self.resolve("process_control_launch_app", in: handles, as: LaunchAppFn.self)
    errorFree = try Self.resolve("idevice_error_free", in: handles, as: ErrorFreeFn.self)
  }

  func activate(
    bundleId: String,
    pairingFilePath: String,
    deviceAddress: String,
    rsdPort: UInt16
  ) throws -> UInt64 {
    guard FileManager.default.isReadableFile(atPath: pairingFilePath) else {
      throw NeoStationActivationError.pairingFileMissing
    }

    var pairing: OpaquePointer?
    try check(
      pairingFilePath.withCString { pairingRead($0, &pairing) },
      fallback: "Failed to read pairing file for post-JIT handoff"
    )
    guard let pairing else {
      throw NeoStationActivationError.incompleteHandle("pairing file handle")
    }
    defer { pairingFree(pairing) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(rsdPort).bigEndian
    let parsed = deviceAddress.withCString {
      inet_pton(AF_INET, $0, &address.sin_addr)
    }
    guard parsed == 1 else {
      throw NeoStationActivationError.invalidDeviceAddress(deviceAddress)
    }

    var adapter: OpaquePointer?
    var handshake: OpaquePointer?
    let tunnelError = "NeoStationHandoff".withCString { hostname in
      withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
          tunnelCreate(
            socketAddress,
            socklen_t(MemoryLayout<sockaddr_in>.stride),
            hostname,
            pairing,
            nil,
            nil,
            &adapter,
            &handshake
          )
        }
      }
    }
    try check(tunnelError, fallback: "Failed to create post-JIT RSD tunnel")
    guard let adapter, let handshake else {
      throw NeoStationActivationError.incompleteHandle("post-JIT RSD tunnel")
    }
    defer {
      handshakeFree(handshake)
      adapterFree(adapter)
    }

    var remoteServer: OpaquePointer?
    try check(
      remoteConnect(adapter, handshake, &remoteServer),
      fallback: "Failed to connect RemoteServer for post-JIT handoff"
    )
    guard let remoteServer else {
      throw NeoStationActivationError.incompleteHandle("post-JIT RemoteServer handle")
    }
    defer { remoteFree(remoteServer) }

    var processControl: OpaquePointer?
    try check(
      processNew(remoteServer, &processControl),
      fallback: "Failed to open process control for post-JIT handoff"
    )
    guard let processControl else {
      throw NeoStationActivationError.incompleteHandle("post-JIT process-control handle")
    }
    defer { processFree(processControl) }

    var pid: UInt64 = 0
    let activationError = bundleId.withCString { bundleIdCString in
      launchApp(
        processControl,
        bundleIdCString,
        nil,
        0,
        nil,
        0,
        false,
        false,
        &pid
      )
    }
    try check(
      activationError,
      fallback: "Failed to return NeoStation to the foreground"
    )

    guard pid > 0 else {
      throw NeoStationActivationError.idevice(
        "process_control returned an invalid NeoStation PID: \(pid)"
      )
    }
    return pid
  }

  private func check(_ error: OpaquePointer?, fallback: String) throws {
    guard let error else { return }
    let record = UnsafeRawPointer(error)
      .assumingMemoryBound(to: HandoffIdeviceErrorRecord.self)
      .pointee
    let detail = record.message.map(String.init(cString:)) ?? fallback
    let code = record.code
    let subCode = record.subCode
    errorFree(error)
    throw NeoStationActivationError.idevice(
      "\(fallback): \(detail) [code \(code), subcode \(subCode)]"
    )
  }

  private static func resolve<T>(
    _ name: String,
    in handles: [UnsafeMutableRawPointer],
    as type: T.Type
  ) throws -> T {
    for handle in handles {
      if let symbol = dlsym(handle, name) {
        return unsafeBitCast(symbol, to: type)
      }
    }
    throw NeoStationActivationError.symbolMissing(name)
  }
}
