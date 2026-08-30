import Darwin
import Flutter
import Foundation
import StikJIT

/// Build-166 registration shim for the experimental MeloNX path.
///
/// The original bridge correctly launches MeloNX suspended, enables JIT with
/// universal.js and detaches. The missing step was the same process-control
/// relaunch that StikDebug performs after detach: suspended=false,
/// terminateExisting=false. Without it, MeloNX remains suspended and iOS can
/// reject the subsequent frontend URL open even though JIT itself succeeded.
public final class StikjitBridgePluginV2: NSObject, FlutterPlugin {
  private static let resumeQueue = DispatchQueue(
    label: "com.neogamelab.neostation.stikjit.resume",
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

    legacy.handle(call) { value in
      guard #available(iOS 17.4, *) else {
        result(value)
        return
      }

      guard
        var response = value as? [String: Any],
        let arguments = call.arguments as? [String: Any],
        let pairingFilePath = arguments["pairingFilePath"] as? String,
        !pairingFilePath.isEmpty,
        let resolvedBundleId = response["bundleId"] as? String,
        !resolvedBundleId.isEmpty
      else {
        // Preserve every legacy error/result unchanged. This shim only adds
        // the post-detach resume to a successful JIT response.
        result(value)
        return
      }

      Self.resumeQueue.async {
        var logs = response["logs"] as? [String] ?? []

        do {
          let configuration = StikJIT.Configuration.default
          let resumedPID = try MeloNxProcessResumer().resume(
            bundleId: resolvedBundleId,
            pairingFilePath: pairingFilePath,
            deviceAddress: configuration.deviceAddress,
            rsdPort: configuration.rsdPort
          )

          logs.append(
            "MeloNX resumed after JIT detach with process_control_launch_app " +
              "(suspended=false, terminateExisting=false), PID \(resumedPID)."
          )
          response["logs"] = logs
          response["resumedPid"] = Int(resumedPID)
          response["resumeSucceeded"] = true
        } catch {
          // Do not discard a JIT success if process-control resume itself fails.
          // Dart will still attempt the frontend URL and the persistent log now
          // contains the exact missing handoff error for the next device test.
          logs.append("MeloNX post-JIT resume failed: \(error.localizedDescription)")
          response["logs"] = logs
          response["resumeSucceeded"] = false
          response["resumeError"] = error.localizedDescription
        }

        DispatchQueue.main.async {
          result(response)
        }
      }
    }
  }
}

@available(iOS 17.4, *)
private final class MeloNxProcessResumer {
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
    // Force dyld to load the vendored StikJIT framework before resolving the
    // idevice symbols it exports.
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

  func resume(
    bundleId: String,
    pairingFilePath: String,
    deviceAddress: String,
    rsdPort: UInt16
  ) throws -> UInt64 {
    var pairing: OpaquePointer?
    try check(
      pairingFilePath.withCString { pairingRead($0, &pairing) },
      fallback: "Failed to read pairing file for post-JIT resume"
    )
    guard let pairing else {
      throw MeloNxResumeError.incompleteHandle("pairing file handle")
    }
    defer { pairingFree(pairing) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(rsdPort).bigEndian
    let parsed = deviceAddress.withCString {
      inet_pton(AF_INET, $0, &address.sin_addr)
    }
    guard parsed == 1 else {
      throw MeloNxResumeError.invalidDeviceAddress(deviceAddress)
    }

    var adapter: OpaquePointer?
    var handshake: OpaquePointer?
    let tunnelError = "NeoStationResume".withCString { hostname in
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
      throw MeloNxResumeError.incompleteHandle("post-JIT RSD tunnel")
    }
    defer {
      handshakeFree(handshake)
      adapterFree(adapter)
    }

    var remoteServer: OpaquePointer?
    try check(
      remoteConnect(adapter, handshake, &remoteServer),
      fallback: "Failed to connect RemoteServer for post-JIT resume"
    )
    guard let remoteServer else {
      throw MeloNxResumeError.incompleteHandle("post-JIT RemoteServer handle")
    }
    defer { remoteFree(remoteServer) }

    var processControl: OpaquePointer?
    try check(
      processNew(remoteServer, &processControl),
      fallback: "Failed to open process control for post-JIT resume"
    )
    guard let processControl else {
      throw MeloNxResumeError.incompleteHandle("post-JIT process-control handle")
    }
    defer { processFree(processControl) }

    var pid: UInt64 = 0
    let launchError = bundleId.withCString { bundleIdCString in
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
      launchError,
      fallback: "Failed to resume MeloNX after JIT detach (\(bundleId))"
    )

    guard pid > 0 else {
      throw MeloNxResumeError.idevice("Post-JIT resume returned an invalid PID: \(pid)")
    }
    return pid
  }

  private func check(_ error: OpaquePointer?, fallback: String) throws {
    guard let error else { return }
    let record = UnsafeRawPointer(error)
      .assumingMemoryBound(to: MeloNxResumeErrorRecord.self)
      .pointee
    let detail = record.message.map(String.init(cString:)) ?? fallback
    let code = record.code
    let subCode = record.subCode
    errorFree(error)
    throw MeloNxResumeError.idevice(
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
    throw MeloNxResumeError.symbolMissing(name)
  }
}

private struct MeloNxResumeErrorRecord {
  let code: Int32
  let subCode: Int32
  let message: UnsafePointer<CChar>?
}

private enum MeloNxResumeError: LocalizedError {
  case symbolMissing(String)
  case invalidDeviceAddress(String)
  case incompleteHandle(String)
  case idevice(String)

  var errorDescription: String? {
    switch self {
    case .symbolMissing(let symbol):
      return "StikJIT framework is missing required resume symbol \(symbol)."
    case .invalidDeviceAddress(let address):
      return "Invalid LocalDevVPN device address during resume: \(address)"
    case .incompleteHandle(let name):
      return "StikJIT resume runtime did not create \(name)."
    case .idevice(let message):
      return message
    }
  }
}
