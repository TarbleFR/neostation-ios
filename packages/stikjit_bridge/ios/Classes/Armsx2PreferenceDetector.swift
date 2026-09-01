import Darwin
import Foundation
import StikJIT

struct Armsx2AutoLoadDetection {
  let enabled: Bool?
  let key: String?
  let logs: [String]
}

private struct Armsx2PreferenceIdeviceErrorRecord {
  let code: Int32
  let subCode: Int32
  let message: UnsafePointer<CChar>?
}

@available(iOS 17.4, *)
final class Armsx2PreferenceDetector {
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

  private typealias HouseArrestConnectFn = @convention(c) (
    OpaquePointer?,
    OpaquePointer?,
    UnsafeMutablePointer<OpaquePointer?>?
  ) -> OpaquePointer?
  private typealias HouseArrestFreeFn = @convention(c) (OpaquePointer?) -> Void
  private typealias HouseArrestVendContainerFn = @convention(c) (
    OpaquePointer?,
    UnsafePointer<CChar>?,
    UnsafeMutablePointer<OpaquePointer?>?
  ) -> OpaquePointer?

  private typealias AfcClientFreeFn = @convention(c) (OpaquePointer?) -> Void
  private typealias AfcFileOpenFn = @convention(c) (
    OpaquePointer?,
    UnsafePointer<CChar>?,
    Int32,
    UnsafeMutablePointer<OpaquePointer?>?
  ) -> OpaquePointer?
  private typealias AfcFileReadEntireFn = @convention(c) (
    OpaquePointer?,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    UnsafeMutablePointer<Int>?
  ) -> OpaquePointer?
  private typealias AfcFileReadDataFreeFn = @convention(c) (
    UnsafeMutablePointer<UInt8>?,
    Int
  ) -> Void
  private typealias AfcFileCloseFn = @convention(c) (OpaquePointer?) -> OpaquePointer?
  private typealias ErrorFreeFn = @convention(c) (OpaquePointer?) -> Void

  private let handles: [UnsafeMutableRawPointer]
  private let pairingRead: PairingReadFn
  private let pairingFree: PairingFreeFn
  private let tunnelCreate: TunnelCreateFn
  private let adapterFree: AdapterFreeFn
  private let handshakeFree: HandshakeFreeFn
  private let houseArrestConnect: HouseArrestConnectFn
  private let houseArrestFree: HouseArrestFreeFn
  private let houseArrestVendContainer: HouseArrestVendContainerFn
  private let afcClientFree: AfcClientFreeFn
  private let afcFileOpen: AfcFileOpenFn
  private let afcFileReadEntire: AfcFileReadEntireFn
  private let afcFileReadDataFree: AfcFileReadDataFreeFn
  private let afcFileClose: AfcFileCloseFn
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
    houseArrestConnect = try Self.resolve(
      "house_arrest_client_connect_rsd",
      in: handles,
      as: HouseArrestConnectFn.self
    )
    houseArrestFree = try Self.resolve(
      "house_arrest_client_free",
      in: handles,
      as: HouseArrestFreeFn.self
    )
    houseArrestVendContainer = try Self.resolve(
      "house_arrest_vend_container",
      in: handles,
      as: HouseArrestVendContainerFn.self
    )
    afcClientFree = try Self.resolve("afc_client_free", in: handles, as: AfcClientFreeFn.self)
    afcFileOpen = try Self.resolve("afc_file_open", in: handles, as: AfcFileOpenFn.self)
    afcFileReadEntire = try Self.resolve(
      "afc_file_read_entire",
      in: handles,
      as: AfcFileReadEntireFn.self
    )
    afcFileReadDataFree = try Self.resolve(
      "afc_file_read_data_free",
      in: handles,
      as: AfcFileReadDataFreeFn.self
    )
    afcFileClose = try Self.resolve("afc_file_close", in: handles, as: AfcFileCloseFn.self)
    errorFree = try Self.resolve("idevice_error_free", in: handles, as: ErrorFreeFn.self)
  }

  func detect(
    bundleId: String,
    pairingFilePath: String,
    deviceAddress: String,
    rsdPort: UInt16
  ) throws -> Armsx2AutoLoadDetection {
    var logs = [String]()
    logs.append("ARMSX2 preference auto-detection: inspecting app container through House Arrest/AFC.")

    var pairing: OpaquePointer?
    try check(
      pairingFilePath.withCString { pairingRead($0, &pairing) },
      fallback: "Failed to read pairing file for ARMSX2 preference detection"
    )
    guard let pairing else {
      throw Armsx2BridgeError.incompleteHandle("ARMSX2 preference pairing file")
    }
    defer { pairingFree(pairing) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(rsdPort).bigEndian
    let parsed = deviceAddress.withCString {
      inet_pton(AF_INET, $0, &address.sin_addr)
    }
    guard parsed == 1 else {
      throw Armsx2BridgeError.invalidDeviceAddress(deviceAddress)
    }

    var adapter: OpaquePointer?
    var handshake: OpaquePointer?
    let tunnelError = "NeoStationARMSX2Prefs".withCString { hostname in
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
    try check(tunnelError, fallback: "Failed to create ARMSX2 preference RSD tunnel")
    guard let adapter, let handshake else {
      throw Armsx2BridgeError.incompleteHandle("ARMSX2 preference RSD tunnel")
    }
    defer {
      handshakeFree(handshake)
      adapterFree(adapter)
    }

    var houseArrest: OpaquePointer?
    try check(
      houseArrestConnect(adapter, handshake, &houseArrest),
      fallback: "Failed to connect House Arrest for ARMSX2 preference detection"
    )
    guard let houseArrest else {
      throw Armsx2BridgeError.incompleteHandle("ARMSX2 House Arrest handle")
    }
    defer { houseArrestFree(houseArrest) }

    var afc: OpaquePointer?
    try check(
      bundleId.withCString { houseArrestVendContainer(houseArrest, $0, &afc) },
      fallback: "Failed to vend the ARMSX2 app container"
    )
    guard let afc else {
      throw Armsx2BridgeError.incompleteHandle("ARMSX2 AFC container")
    }
    defer { afcClientFree(afc) }

    var preferencePaths = [
      "Library/Preferences/\(bundleId).plist",
      "Library/Preferences/com.armsx2.ios.plist",
    ]
    if let suffixRange = bundleId.range(of: ".ios.") {
      let base = String(bundleId[..<suffixRange.upperBound]).dropLast()
      preferencePaths.append("Library/Preferences/\(base).plist")
    }

    var seen = Set<String>()
    preferencePaths = preferencePaths.filter { seen.insert($0).inserted }

    for preferencePath in preferencePaths {
      guard let data = try? readFile(afc: afc, path: preferencePath) else {
        logs.append("ARMSX2 preference file not readable: \(preferencePath)")
        continue
      }

      logs.append("ARMSX2 preference file read: \(preferencePath) (\(data.count) bytes).")
      guard
        let plist = try? PropertyListSerialization.propertyList(
          from: data,
          options: [],
          format: nil
        )
      else {
        logs.append("ARMSX2 preference plist could not be decoded: \(preferencePath)")
        continue
      }

      var candidates = [(key: String, value: Bool, score: Int)]()
      collectCandidates(plist, path: "", into: &candidates)
      candidates.sort {
        if $0.score != $1.score { return $0.score > $1.score }
        return $0.key < $1.key
      }

      for candidate in candidates.prefix(8) where candidate.score > 0 {
        logs.append(
          "ARMSX2 preference candidate: \(candidate.key)=\(candidate.value) score=\(candidate.score)"
        )
      }

      if let best = candidates.first, best.score >= 90 {
        logs.append(
          "STATE: ARMSX2_AUTOLOAD_PREFERENCE_DETECTED key=\(best.key) value=\(best.value)"
        )
        return Armsx2AutoLoadDetection(
          enabled: best.value,
          key: best.key,
          logs: logs
        )
      }
    }

    logs.append("STATE: ARMSX2_AUTOLOAD_PREFERENCE_UNAVAILABLE")
    logs.append("No high-confidence Automatic Load Last Game boolean was found; NeoStation will use its saved fallback preference.")
    return Armsx2AutoLoadDetection(enabled: nil, key: nil, logs: logs)
  }

  private func readFile(afc: OpaquePointer, path: String) throws -> Data {
    var file: OpaquePointer?
    try check(
      path.withCString { afcFileOpen(afc, $0, 1, &file) },
      fallback: "Failed to open AFC file \(path)"
    )
    guard let file else {
      throw Armsx2BridgeError.incompleteHandle("AFC file \(path)")
    }
    defer {
      if let closeError = afcFileClose(file) {
        errorFree(closeError)
      }
    }

    var rawData: UnsafeMutablePointer<UInt8>?
    var length = 0
    try check(
      afcFileReadEntire(file, &rawData, &length),
      fallback: "Failed to read AFC file \(path)"
    )
    guard let rawData, length >= 0 else {
      return Data()
    }
    defer { afcFileReadDataFree(rawData, length) }
    return Data(bytes: rawData, count: length)
  }

  private func collectCandidates(
    _ value: Any,
    path: String,
    into candidates: inout [(key: String, value: Bool, score: Int)]
  ) {
    if let dictionary = value as? [String: Any] {
      for (key, child) in dictionary {
        let childPath = path.isEmpty ? key : "\(path).\(key)"
        if let boolValue = child as? Bool {
          candidates.append(
            (key: childPath, value: boolValue, score: preferenceScore(key))
          )
        }
        collectCandidates(child, path: childPath, into: &candidates)
      }
      return
    }

    if let array = value as? [Any] {
      for (index, child) in array.enumerated() {
        collectCandidates(child, path: "\(path)[\(index)]", into: &candidates)
      }
    }
  }

  private func preferenceScore(_ key: String) -> Int {
    let normalized = key
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }

    if normalized.contains("automaticloadlastgame") { return 200 }
    if normalized.contains("autoloadlastgame") { return 190 }
    if normalized.contains("loadlastgame") { return 170 }
    if normalized.contains("lastgame") && normalized.contains("autoload") {
      return 160
    }
    if normalized.contains("lastgame") && normalized.contains("automatic") {
      return 150
    }
    if normalized.contains("lastgame") && normalized.contains("load") {
      return 140
    }
    if normalized.contains("skipintro") && normalized.contains("lastgame") {
      return 130
    }
    if normalized.contains("autoload") && normalized.contains("game") {
      return 100
    }
    if normalized.contains("lastgame") { return 70 }
    if normalized.contains("skipintro") { return 40 }
    return 0
  }

  private func check(_ error: OpaquePointer?, fallback: String) throws {
    guard let error else { return }
    let record = UnsafeRawPointer(error)
      .assumingMemoryBound(to: Armsx2PreferenceIdeviceErrorRecord.self)
      .pointee
    let detail = record.message.map(String.init(cString:)) ?? fallback
    let code = record.code
    let subCode = record.subCode
    errorFree(error)
    throw Armsx2BridgeError.idevice(
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
    throw Armsx2BridgeError.symbolMissing(name)
  }
}
