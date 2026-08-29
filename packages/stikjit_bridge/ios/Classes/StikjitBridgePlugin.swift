import Darwin
import Flutter
import Foundation
import StikJIT

public final class StikjitBridgePlugin: NSObject, FlutterPlugin {
  private static let jitQueue = DispatchQueue(
    label: "com.neogamelab.neostation.stikjit",
    qos: .userInitiated
  )

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "neostation/stikjit",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(StikjitBridgePlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "enableMeloNxJit" else {
      result(FlutterMethodNotImplemented)
      return
    }

    guard #available(iOS 17.4, *) else {
      result(
        FlutterError(
          code: "stikjit_unsupported_ios",
          message: "Built-in StikJIT requires iOS 17.4 or newer.",
          details: nil
        )
      )
      return
    }

    guard
      let arguments = call.arguments as? [String: Any],
      let pairingFilePath = arguments["pairingFilePath"] as? String,
      !pairingFilePath.isEmpty,
      let bundleId = arguments["bundleId"] as? String,
      !bundleId.isEmpty
    else {
      result(
        FlutterError(
          code: "stikjit_invalid_arguments",
          message: "Pairing file path and MeloNX bundle identifier hint are required.",
          details: nil
        )
      )
      return
    }

    Self.jitQueue.async {
      do {
        let response = try Self.enableMeloNxJit(
          pairingFilePath: pairingFilePath,
          bundleIdHint: bundleId
        )
        DispatchQueue.main.async { result(response) }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "stikjit_enable_failed",
              message: error.localizedDescription,
              details: String(reflecting: error)
            )
          )
        }
      }
    }
  }

  @available(iOS 17.4, *)
  private static func enableMeloNxJit(
    pairingFilePath: String,
    bundleIdHint: String
  ) throws -> [String: Any] {
    let pairingFile = URL(fileURLWithPath: pairingFilePath)
    guard FileManager.default.isReadableFile(atPath: pairingFile.path) else {
      throw StikjitBridgeError.pairingFileMissing
    }

    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let stikRoot = applicationSupport.appendingPathComponent("StikJIT", isDirectory: true)
    try FileManager.default.createDirectory(
      at: stikRoot,
      withIntermediateDirectories: true
    )

    let configuration = StikJIT.Configuration.default
    let ddiPaths = DDIPaths.default(in: stikRoot)
    var logs = [String]()

    logs.append("Preparing LocalDevVPN/RSD endpoint and Developer Disk Image.")
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
      throw StikjitBridgeError.deviceNotReady(reason)
    case .preparationFailed(let reason):
      throw StikjitBridgeError.deviceNotReady(reason)
    @unknown default:
      throw StikjitBridgeError.deviceNotReady(
        "StikJIT returned an unknown device-readiness state."
      )
    }

    // Sideloaders such as SideStore/Plume can rewrite MeloNX's bundle ID,
    // commonly to values such as com.stossy11.MeloNX.XXXXXX. The compile-time
    // bundleId is therefore only a hint. Discover the actual installed MeloNX
    // app through idevice's AppService on the same RSD tunnel before launch.
    let runtime = try IdeviceRuntime()
    let launch = try runtime.launchMeloNxSuspended(
      preferredBundleId: bundleIdHint,
      pairingFilePath: pairingFile.path,
      deviceAddress: configuration.deviceAddress,
      rsdPort: configuration.rsdPort
    )
    logs.append("Detected MeloNX bundle ID: \(launch.bundleId).")
    logs.append("MeloNX launched suspended with PID \(launch.pid).")

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
    logs.append("StikJIT completed and detached from MeloNX.")

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

private enum StikjitBridgeError: LocalizedError {
  case pairingFileMissing
  case deviceNotReady(String)
  case symbolMissing(String)
  case invalidDeviceAddress(String)
  case idevice(String)
  case incompleteHandle(String)
  case unsupportedAppListAbi
  case meloNxNotFound(String)

  var errorDescription: String? {
    switch self {
    case .pairingFileMissing:
      return "The selected pairing file is no longer readable."
    case .deviceNotReady(let reason):
      return "StikJIT device preparation failed: \(reason)"
    case .symbolMissing(let symbol):
      return "StikJIT framework is missing required idevice symbol \(symbol)."
    case .invalidDeviceAddress(let address):
      return "Invalid LocalDevVPN device address: \(address)"
    case .idevice(let message):
      return message
    case .incompleteHandle(let name):
      return "StikJIT idevice runtime did not create \(name)."
    case .unsupportedAppListAbi:
      return "NeoStation cannot inspect installed apps on this device architecture."
    case .meloNxNotFound(let hint):
      return "MeloNX was not found in the installed app list. Bundle hint: \(hint)."
    }
  }
}

private struct IdeviceErrorRecord {
  let code: Int32
  let subCode: Int32
  let message: UnsafePointer<CChar>?
}

private struct SuspendedMeloNxLaunch {
  let pid: Int32
  let bundleId: String
}

private struct MeloNxCandidate {
  let bundleId: String
  let name: String
  let path: String
  let score: Int
}

private final class IdeviceRuntime {
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

  private typealias AppServiceConnectFn = @convention(c) (
    OpaquePointer?,
    OpaquePointer?,
    UnsafeMutablePointer<OpaquePointer?>?
  ) -> OpaquePointer?
  private typealias AppServiceFreeFn = @convention(c) (OpaquePointer?) -> Void
  private typealias AppServiceListAppsFn = @convention(c) (
    OpaquePointer?,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    UnsafeMutablePointer<UInt>?
  ) -> OpaquePointer?
  private typealias AppServiceFreeAppListFn = @convention(c) (
    UnsafeMutableRawPointer?,
    UInt
  ) -> Void

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
  private let appServiceConnect: AppServiceConnectFn
  private let appServiceFree: AppServiceFreeFn
  private let appServiceListApps: AppServiceListAppsFn
  private let appServiceFreeAppList: AppServiceFreeAppListFn
  private let remoteConnect: RemoteConnectFn
  private let remoteFree: RemoteFreeFn
  private let processNew: ProcessNewFn
  private let processFree: ProcessFreeFn
  private let launchApp: LaunchAppFn
  private let errorFree: ErrorFreeFn

  init() throws {
    // Force dyld to load StikJIT before resolving the idevice symbols that the
    // framework embeds with -force_load.
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
    appServiceConnect = try Self.resolve("app_service_connect_rsd", in: handles, as: AppServiceConnectFn.self)
    appServiceFree = try Self.resolve("app_service_free", in: handles, as: AppServiceFreeFn.self)
    appServiceListApps = try Self.resolve("app_service_list_apps", in: handles, as: AppServiceListAppsFn.self)
    appServiceFreeAppList = try Self.resolve(
      "app_service_free_app_list",
      in: handles,
      as: AppServiceFreeAppListFn.self
    )
    remoteConnect = try Self.resolve("remote_server_connect_rsd", in: handles, as: RemoteConnectFn.self)
    remoteFree = try Self.resolve("remote_server_free", in: handles, as: RemoteFreeFn.self)
    processNew = try Self.resolve("process_control_new", in: handles, as: ProcessNewFn.self)
    processFree = try Self.resolve("process_control_free", in: handles, as: ProcessFreeFn.self)
    launchApp = try Self.resolve("process_control_launch_app", in: handles, as: LaunchAppFn.self)
    errorFree = try Self.resolve("idevice_error_free", in: handles, as: ErrorFreeFn.self)
  }

  func launchMeloNxSuspended(
    preferredBundleId: String,
    pairingFilePath: String,
    deviceAddress: String,
    rsdPort: UInt16
  ) throws -> SuspendedMeloNxLaunch {
    var pairing: OpaquePointer?
    try check(
      pairingFilePath.withCString { pairingRead($0, &pairing) },
      fallback: "Failed to read pairing file"
    )
    guard let pairing else {
      throw StikjitBridgeError.incompleteHandle("pairing file handle")
    }
    defer { pairingFree(pairing) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(rsdPort).bigEndian
    let parsed = deviceAddress.withCString {
      inet_pton(AF_INET, $0, &address.sin_addr)
    }
    guard parsed == 1 else {
      throw StikjitBridgeError.invalidDeviceAddress(deviceAddress)
    }

    var adapter: OpaquePointer?
    var handshake: OpaquePointer?
    let tunnelError = "NeoStation".withCString { hostname in
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
    try check(tunnelError, fallback: "Failed to create StikJIT RSD tunnel")
    guard let adapter, let handshake else {
      throw StikjitBridgeError.incompleteHandle("RSD tunnel")
    }
    defer {
      handshakeFree(handshake)
      adapterFree(adapter)
    }

    let resolvedBundleId = try discoverMeloNxBundleId(
      preferredBundleId: preferredBundleId,
      adapter: adapter,
      handshake: handshake
    )

    var remoteServer: OpaquePointer?
    try check(
      remoteConnect(adapter, handshake, &remoteServer),
      fallback: "Failed to connect RemoteServer"
    )
    guard let remoteServer else {
      throw StikjitBridgeError.incompleteHandle("RemoteServer handle")
    }
    defer { remoteFree(remoteServer) }

    var processControl: OpaquePointer?
    try check(
      processNew(remoteServer, &processControl),
      fallback: "Failed to open process control"
    )
    guard let processControl else {
      throw StikjitBridgeError.incompleteHandle("process-control handle")
    }
    defer { processFree(processControl) }

    var pid: UInt64 = 0
    let launchError = resolvedBundleId.withCString { bundleIdCString in
      launchApp(
        processControl,
        bundleIdCString,
        nil,
        0,
        nil,
        0,
        true,
        false,
        &pid
      )
    }
    try check(
      launchError,
      fallback: "Failed to launch MeloNX suspended (\(resolvedBundleId))"
    )

    guard pid > 0, pid <= UInt64(Int32.max) else {
      throw StikjitBridgeError.idevice("MeloNX returned an invalid PID: \(pid)")
    }
    return SuspendedMeloNxLaunch(pid: Int32(pid), bundleId: resolvedBundleId)
  }

  private func discoverMeloNxBundleId(
    preferredBundleId: String,
    adapter: OpaquePointer,
    handshake: OpaquePointer
  ) throws -> String {
    // AppListEntryC is an exported C struct from idevice. StikJIT is arm64-only
    // on iOS, so parse the stable 64-bit C ABI layout without linking another
    // copy of libidevice into NeoStation.
    guard MemoryLayout<UnsafeRawPointer>.size == 8 else {
      throw StikjitBridgeError.unsupportedAppListAbi
    }

    var appService: OpaquePointer?
    try check(
      appServiceConnect(adapter, handshake, &appService),
      fallback: "Failed to connect AppService for MeloNX discovery"
    )
    guard let appService else {
      throw StikjitBridgeError.incompleteHandle("AppService handle")
    }
    defer { appServiceFree(appService) }

    var appsRaw: UnsafeMutableRawPointer?
    var appCount: UInt = 0
    try check(
      appServiceListApps(
        appService,
        0,
        1,
        0,
        0,
        0,
        &appsRaw,
        &appCount
      ),
      fallback: "Failed to list installed apps"
    )

    guard let appsRaw, appCount > 0 else {
      throw StikjitBridgeError.meloNxNotFound(preferredBundleId)
    }
    defer { appServiceFreeAppList(appsRaw, appCount) }

    let preferred = preferredBundleId.lowercased()
    let stride = 80
    let nameOffset = 8
    let pathOffset = 24
    let bundleIdentifierOffset = 32
    var candidates = [MeloNxCandidate]()

    for index in 0..<Int(appCount) {
      let record = UnsafeRawPointer(appsRaw).advanced(by: index * stride)
      guard let bundleId = Self.readCString(record, offset: bundleIdentifierOffset),
            !bundleId.isEmpty else {
        continue
      }
      let name = Self.readCString(record, offset: nameOffset) ?? ""
      let path = Self.readCString(record, offset: pathOffset) ?? ""

      let bundleLower = bundleId.lowercased()
      let nameLower = name.lowercased()
      let pathLower = path.lowercased()
      var score = 0

      if bundleLower == preferred {
        score += 200
      }
      if nameLower == "melonx" {
        score += 150
      } else if nameLower.contains("melonx") {
        score += 80
      }
      if bundleLower.contains(".melonx") || bundleLower.hasSuffix("melonx") {
        score += 120
      } else if bundleLower.contains("melonx") {
        score += 70
      }
      if pathLower.contains("/melonx.app") {
        score += 100
      }

      if score > 0 {
        candidates.append(
          MeloNxCandidate(bundleId: bundleId, name: name, path: path, score: score)
        )
      }
    }

    guard let best = candidates.sorted(by: { lhs, rhs in
      if lhs.score != rhs.score {
        return lhs.score > rhs.score
      }
      return lhs.bundleId.localizedCaseInsensitiveCompare(rhs.bundleId) == .orderedAscending
    }).first else {
      throw StikjitBridgeError.meloNxNotFound(preferredBundleId)
    }

    return best.bundleId
  }

  private static func readCString(
    _ record: UnsafeRawPointer,
    offset: Int
  ) -> String? {
    guard let pointer = record.advanced(by: offset).load(as: UnsafePointer<CChar>?.self) else {
      return nil
    }
    return String(cString: pointer)
  }

  private func check(_ error: OpaquePointer?, fallback: String) throws {
    guard let error else { return }
    let record = UnsafeRawPointer(error)
      .assumingMemoryBound(to: IdeviceErrorRecord.self)
      .pointee
    let detail = record.message.map(String.init(cString:)) ?? fallback
    let code = record.code
    let subCode = record.subCode
    errorFree(error)
    throw StikjitBridgeError.idevice(
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
    throw StikjitBridgeError.symbolMissing(name)
  }
}
