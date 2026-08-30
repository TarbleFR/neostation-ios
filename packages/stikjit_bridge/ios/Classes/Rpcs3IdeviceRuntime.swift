import Darwin
import Foundation
import StikJIT

private struct Rpcs3IdeviceErrorRecord {
  let code: Int32
  let subCode: Int32
  let message: UnsafePointer<CChar>?
}

struct SuspendedRpcs3Launch {
  let pid: Int32
  let bundleId: String
}

private struct Rpcs3Candidate {
  let bundleId: String
  let name: String
  let path: String
  let executable: String
  let score: Int
}

@available(iOS 17.4, *)
final class Rpcs3IdeviceRuntime {
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

  private typealias InstallationProxyConnectFn = @convention(c) (
    OpaquePointer?,
    OpaquePointer?,
    UnsafeMutablePointer<OpaquePointer?>?
  ) -> OpaquePointer?
  private typealias InstallationProxyFreeFn = @convention(c) (OpaquePointer?) -> Void
  private typealias InstallationProxyGetAppsFn = @convention(c) (
    OpaquePointer?,
    UnsafePointer<CChar>?,
    UnsafePointer<UnsafePointer<CChar>?>?,
    Int,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    UnsafeMutablePointer<Int>?
  ) -> OpaquePointer?

  private typealias PlistFreeFn = @convention(c) (OpaquePointer?) -> Void
  private typealias PlistToBinFn = @convention(c) (
    OpaquePointer?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    UnsafeMutablePointer<UInt32>?
  ) -> Int32
  private typealias PlistMemFreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
  private typealias IdeviceDataFreeFn = @convention(c) (
    UnsafeMutablePointer<UInt8>?,
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
  private let installationProxyConnect: InstallationProxyConnectFn
  private let installationProxyFree: InstallationProxyFreeFn
  private let installationProxyGetApps: InstallationProxyGetAppsFn
  private let plistFree: PlistFreeFn
  private let plistToBin: PlistToBinFn
  private let plistMemFree: PlistMemFreeFn
  private let ideviceDataFree: IdeviceDataFreeFn
  private let remoteConnect: RemoteConnectFn
  private let remoteFree: RemoteFreeFn
  private let processNew: ProcessNewFn
  private let processFree: ProcessFreeFn
  private let launchApp: LaunchAppFn
  private let errorFree: ErrorFreeFn

  init() throws {
    // Force dyld to load StikJIT before resolving the idevice symbols embedded
    // in the framework.
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

    pairingRead = try Self.resolve(
      "rp_pairing_file_read",
      in: handles,
      as: PairingReadFn.self
    )
    pairingFree = try Self.resolve(
      "rp_pairing_file_free",
      in: handles,
      as: PairingFreeFn.self
    )
    tunnelCreate = try Self.resolve(
      "tunnel_create_rppairing",
      in: handles,
      as: TunnelCreateFn.self
    )
    adapterFree = try Self.resolve(
      "adapter_free",
      in: handles,
      as: AdapterFreeFn.self
    )
    handshakeFree = try Self.resolve(
      "rsd_handshake_free",
      in: handles,
      as: HandshakeFreeFn.self
    )
    installationProxyConnect = try Self.resolve(
      "installation_proxy_connect_rsd",
      in: handles,
      as: InstallationProxyConnectFn.self
    )
    installationProxyFree = try Self.resolve(
      "installation_proxy_client_free",
      in: handles,
      as: InstallationProxyFreeFn.self
    )
    installationProxyGetApps = try Self.resolve(
      "installation_proxy_get_apps",
      in: handles,
      as: InstallationProxyGetAppsFn.self
    )
    plistFree = try Self.resolve(
      "plist_free",
      in: handles,
      as: PlistFreeFn.self
    )
    plistToBin = try Self.resolve(
      "plist_to_bin",
      in: handles,
      as: PlistToBinFn.self
    )
    plistMemFree = try Self.resolve(
      "plist_mem_free",
      in: handles,
      as: PlistMemFreeFn.self
    )
    ideviceDataFree = try Self.resolve(
      "idevice_data_free",
      in: handles,
      as: IdeviceDataFreeFn.self
    )
    remoteConnect = try Self.resolve(
      "remote_server_connect_rsd",
      in: handles,
      as: RemoteConnectFn.self
    )
    remoteFree = try Self.resolve(
      "remote_server_free",
      in: handles,
      as: RemoteFreeFn.self
    )
    processNew = try Self.resolve(
      "process_control_new",
      in: handles,
      as: ProcessNewFn.self
    )
    processFree = try Self.resolve(
      "process_control_free",
      in: handles,
      as: ProcessFreeFn.self
    )
    launchApp = try Self.resolve(
      "process_control_launch_app",
      in: handles,
      as: LaunchAppFn.self
    )
    errorFree = try Self.resolve(
      "idevice_error_free",
      in: handles,
      as: ErrorFreeFn.self
    )
  }

  func launchRpcs3Suspended(
    preferredBundleId: String,
    pairingFilePath: String,
    deviceAddress: String,
    rsdPort: UInt16
  ) throws -> SuspendedRpcs3Launch {
    var pairing: OpaquePointer?
    try check(
      pairingFilePath.withCString { pairingRead($0, &pairing) },
      fallback: "Failed to read pairing file for RPCS3"
    )
    guard let pairing else {
      throw Rpcs3BridgeError.incompleteHandle("pairing file handle")
    }
    defer { pairingFree(pairing) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(rsdPort).bigEndian
    let parsed = deviceAddress.withCString {
      inet_pton(AF_INET, $0, &address.sin_addr)
    }
    guard parsed == 1 else {
      throw Rpcs3BridgeError.invalidDeviceAddress(deviceAddress)
    }

    var adapter: OpaquePointer?
    var handshake: OpaquePointer?
    let tunnelError = "NeoStationRPCS3".withCString { hostname in
      withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(
          to: sockaddr.self,
          capacity: 1
        ) { socketAddress in
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
    try check(
      tunnelError,
      fallback: "Failed to create RPCS3 StikJIT RSD tunnel"
    )
    guard let adapter, let handshake else {
      throw Rpcs3BridgeError.incompleteHandle("RPCS3 RSD tunnel")
    }
    defer {
      handshakeFree(handshake)
      adapterFree(adapter)
    }

    let resolvedBundleId = try discoverRpcs3BundleId(
      preferredBundleId: preferredBundleId,
      adapter: adapter,
      handshake: handshake
    )

    var remoteServer: OpaquePointer?
    try check(
      remoteConnect(adapter, handshake, &remoteServer),
      fallback: "Failed to connect RemoteServer for RPCS3"
    )
    guard let remoteServer else {
      throw Rpcs3BridgeError.incompleteHandle("RPCS3 RemoteServer handle")
    }
    defer { remoteFree(remoteServer) }

    var processControl: OpaquePointer?
    try check(
      processNew(remoteServer, &processControl),
      fallback: "Failed to open process control for RPCS3"
    )
    guard let processControl else {
      throw Rpcs3BridgeError.incompleteHandle(
        "RPCS3 process-control handle"
      )
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
      fallback: "Failed to launch RPCS3 suspended (\(resolvedBundleId))"
    )

    guard pid > 0, pid <= UInt64(Int32.max) else {
      throw Rpcs3BridgeError.idevice(
        "RPCS3 returned an invalid PID: \(pid)"
      )
    }
    return SuspendedRpcs3Launch(
      pid: Int32(pid),
      bundleId: resolvedBundleId
    )
  }

  private func discoverRpcs3BundleId(
    preferredBundleId: String,
    adapter: OpaquePointer,
    handshake: OpaquePointer
  ) throws -> String {
    var installationProxy: OpaquePointer?
    try check(
      installationProxyConnect(adapter, handshake, &installationProxy),
      fallback: "Failed to connect Installation Proxy for RPCS3 discovery"
    )
    guard let installationProxy else {
      throw Rpcs3BridgeError.incompleteHandle(
        "RPCS3 Installation Proxy handle"
      )
    }
    defer { installationProxyFree(installationProxy) }

    var rawApps: UnsafeMutableRawPointer?
    var appCount = 0
    try check(
      installationProxyGetApps(
        installationProxy,
        nil,
        nil,
        0,
        &rawApps,
        &appCount
      ),
      fallback: "Failed to fetch installed apps for RPCS3 discovery"
    )

    guard let rawApps, appCount > 0 else {
      throw Rpcs3BridgeError.rpcs3NotFound(preferredBundleId)
    }

    let apps = rawApps.assumingMemoryBound(to: OpaquePointer?.self)
    defer {
      for index in 0..<appCount {
        plistFree(apps[index])
      }
      ideviceDataFree(
        rawApps.assumingMemoryBound(to: UInt8.self),
        UInt(appCount * MemoryLayout<OpaquePointer?>.stride)
      )
    }

    let preferred = preferredBundleId.lowercased()
    var candidates = [Rpcs3Candidate]()

    for index in 0..<appCount {
      guard let app = apps[index] else { continue }

      var binaryPlist: UnsafeMutablePointer<CChar>?
      var binaryLength: UInt32 = 0
      guard plistToBin(app, &binaryPlist, &binaryLength) == 0,
            let binaryPlist,
            binaryLength > 0 else {
        continue
      }

      let data = Data(bytes: binaryPlist, count: Int(binaryLength))
      plistMemFree(UnsafeMutableRawPointer(binaryPlist))

      guard
        let plist = try? PropertyListSerialization.propertyList(
          from: data,
          options: [],
          format: nil
        ),
        let dictionary = plist as? [String: Any],
        let bundleId = dictionary["CFBundleIdentifier"] as? String,
        !bundleId.isEmpty
      else {
        continue
      }

      let name = (dictionary["CFBundleDisplayName"] as? String)
        ?? (dictionary["CFBundleName"] as? String)
        ?? ""
      let path = dictionary["Path"] as? String ?? ""
      let executable = dictionary["CFBundleExecutable"] as? String ?? ""

      let bundleLower = bundleId.lowercased()
      let nameLower = name.lowercased()
      let pathLower = path.lowercased()
      let executableLower = executable.lowercased()
      var score = 0

      if bundleLower == preferred {
        score += 320
      }
      if nameLower == "rpcs3" || nameLower == "rpcs3 ios" {
        score += 280
      } else if nameLower.contains("rpcs3") {
        score += 200
      }
      if bundleLower.contains("rpcs3") {
        score += 240
      }
      if pathLower.contains("/rpcs3.app") ||
          pathLower.contains("/rpcs3-ios.app") {
        score += 200
      }
      if executableLower == "rpcs3" || executableLower == "rpcs3-ios" {
        score += 180
      } else if executableLower.contains("rpcs3") {
        score += 120
      }

      if score > 0 {
        candidates.append(
          Rpcs3Candidate(
            bundleId: bundleId,
            name: name,
            path: path,
            executable: executable,
            score: score
          )
        )
      }
    }

    guard let best = candidates.sorted(by: { lhs, rhs in
      if lhs.score != rhs.score {
        return lhs.score > rhs.score
      }
      return lhs.bundleId.localizedCaseInsensitiveCompare(rhs.bundleId)
        == .orderedAscending
    }).first else {
      throw Rpcs3BridgeError.rpcs3NotFound(preferredBundleId)
    }

    return best.bundleId
  }

  private func check(_ error: OpaquePointer?, fallback: String) throws {
    guard let error else { return }
    let record = UnsafeRawPointer(error)
      .assumingMemoryBound(to: Rpcs3IdeviceErrorRecord.self)
      .pointee
    let detail = record.message.map(String.init(cString:)) ?? fallback
    let code = record.code
    let subCode = record.subCode
    errorFree(error)
    throw Rpcs3BridgeError.idevice(
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
    throw Rpcs3BridgeError.symbolMissing(name)
  }
}
