import Darwin
import Foundation
import StikJIT

private struct Armsx2HandoffIdeviceErrorRecord {
  let code: Int32
  let subCode: Int32
  let message: UnsafePointer<CChar>?
}

private enum Armsx2NeoStationActivationError: LocalizedError {
  case pairingFileMissing
  case invalidDeviceAddress(String)
  case symbolMissing(String)
  case incompleteHandle(String)
  case idevice(String)

  var errorDescription: String? {
    switch self {
    case .pairingFileMissing:
      return "The pairing file is no longer readable during the ARMSX2 post-JIT handoff."
    case .invalidDeviceAddress(let address):
      return "Invalid LocalDevVPN device address during ARMSX2 handoff: \(address)"
    case .symbolMissing(let symbol):
      return "StikJIT framework is missing required ARMSX2 handoff symbol \(symbol)."
    case .incompleteHandle(let name):
      return "The ARMSX2 post-JIT handoff did not create \(name)."
    case .idevice(let message):
      return message
    }
  }
}

@available(iOS 17.4, *)
final class Armsx2NeoStationProcessActivator {
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

  func activate(
    bundleId: String,
    pairingFilePath: String,
    deviceAddress: String,
    rsdPort: UInt16
  ) throws -> UInt64 {
    guard FileManager.default.isReadableFile(atPath: pairingFilePath) else {
      throw Armsx2NeoStationActivationError.pairingFileMissing
    }

    var pairing: OpaquePointer?
    try check(
      pairingFilePath.withCString { pairingRead($0, &pairing) },
      fallback: "Failed to read pairing file for ARMSX2 post-JIT handoff"
    )
    guard let pairing else {
      throw Armsx2NeoStationActivationError.incompleteHandle(
        "pairing file handle"
      )
    }
    defer { pairingFree(pairing) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(rsdPort).bigEndian
    let parsed = deviceAddress.withCString {
      inet_pton(AF_INET, $0, &address.sin_addr)
    }
    guard parsed == 1 else {
      throw Armsx2NeoStationActivationError.invalidDeviceAddress(deviceAddress)
    }

    var adapter: OpaquePointer?
    var handshake: OpaquePointer?
    let tunnelError = "NeoStationARMSX2Handoff".withCString { hostname in
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
      fallback: "Failed to create ARMSX2 post-JIT RSD tunnel"
    )
    guard let adapter, let handshake else {
      throw Armsx2NeoStationActivationError.incompleteHandle(
        "ARMSX2 post-JIT RSD tunnel"
      )
    }
    defer {
      handshakeFree(handshake)
      adapterFree(adapter)
    }

    var remoteServer: OpaquePointer?
    try check(
      remoteConnect(adapter, handshake, &remoteServer),
      fallback: "Failed to connect RemoteServer for ARMSX2 post-JIT handoff"
    )
    guard let remoteServer else {
      throw Armsx2NeoStationActivationError.incompleteHandle(
        "ARMSX2 post-JIT RemoteServer handle"
      )
    }
    defer { remoteFree(remoteServer) }

    var processControl: OpaquePointer?
    try check(
      processNew(remoteServer, &processControl),
      fallback: "Failed to open process control for ARMSX2 post-JIT handoff"
    )
    guard let processControl else {
      throw Armsx2NeoStationActivationError.incompleteHandle(
        "ARMSX2 post-JIT process-control handle"
      )
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
      fallback: "Failed to return NeoStation to the foreground after ARMSX2 JIT"
    )

    guard pid > 0 else {
      throw Armsx2NeoStationActivationError.idevice(
        "process_control returned an invalid NeoStation PID: \(pid)"
      )
    }
    return pid
  }

  private func check(_ error: OpaquePointer?, fallback: String) throws {
    guard let error else { return }
    let record = UnsafeRawPointer(error)
      .assumingMemoryBound(to: Armsx2HandoffIdeviceErrorRecord.self)
      .pointee
    let detail = record.message.map(String.init(cString:)) ?? fallback
    let code = record.code
    let subCode = record.subCode
    errorFree(error)
    throw Armsx2NeoStationActivationError.idevice(
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
    throw Armsx2NeoStationActivationError.symbolMissing(name)
  }
}
