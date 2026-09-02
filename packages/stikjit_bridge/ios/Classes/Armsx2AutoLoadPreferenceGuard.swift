import Darwin
import Foundation
import StikJIT

struct Armsx2AutoLoadPreferenceToken {
  let bundleId: String
  let preferencePath: String
  let originalData: Data
  let detectedKey: String
}

struct Armsx2AutoLoadPreferenceState {
  let detectedEnabled: Bool?
  let detectedKey: String?
  let token: Armsx2AutoLoadPreferenceToken?
  let logs: [String]
}

private struct Armsx2AutoLoadGuardErrorRecord {
  let code: Int32
  let subCode: Int32
  let message: UnsafePointer<CChar>?
}

@available(iOS 17.4, *)
final class Armsx2AutoLoadPreferenceGuard {
  private enum PathComponent {
    case key(String)
    case index(Int)
  }

  private struct Candidate {
    let components: [PathComponent]
    let displayPath: String
    let value: Bool
    let score: Int
  }

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
  private typealias AfcFileWriteFn = @convention(c) (
    OpaquePointer?,
    UnsafePointer<UInt8>?,
    Int
  ) -> OpaquePointer?
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
  private let afcFileWrite: AfcFileWriteFn
  private let afcFileClose: AfcFileCloseFn
  private let errorFree: ErrorFreeFn

  init() throws {
    _ = StikJIT.isTXMPresent

    var loadedHandles = [UnsafeMutableRawPointer]()
    if let frameworks = Bundle.main.privateFrameworksURL,
       let frameworkHandle = dlopen(
        frameworks.appendingPathComponent("StikJIT.framework/StikJIT").path,
        RTLD_NOW | RTLD_GLOBAL
       ) {
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
    houseArrestConnect = try Self.resolve("house_arrest_client_connect_rsd", in: handles, as: HouseArrestConnectFn.self)
    houseArrestFree = try Self.resolve("house_arrest_client_free", in: handles, as: HouseArrestFreeFn.self)
    houseArrestVendContainer = try Self.resolve("house_arrest_vend_container", in: handles, as: HouseArrestVendContainerFn.self)
    afcClientFree = try Self.resolve("afc_client_free", in: handles, as: AfcClientFreeFn.self)
    afcFileOpen = try Self.resolve("afc_file_open", in: handles, as: AfcFileOpenFn.self)
    afcFileReadEntire = try Self.resolve("afc_file_read_entire", in: handles, as: AfcFileReadEntireFn.self)
    afcFileReadDataFree = try Self.resolve("afc_file_read_data_free", in: handles, as: AfcFileReadDataFreeFn.self)
    afcFileWrite = try Self.resolve("afc_file_write", in: handles, as: AfcFileWriteFn.self)
    afcFileClose = try Self.resolve("afc_file_close", in: handles, as: AfcFileCloseFn.self)
    errorFree = try Self.resolve("idevice_error_free", in: handles, as: ErrorFreeFn.self)
  }

  func temporarilyDisableIfEnabled(
    bundleId: String,
    pairingFilePath: String,
    deviceAddress: String,
    rsdPort: UInt16
  ) throws -> Armsx2AutoLoadPreferenceState {
    try withAfc(
      bundleId: bundleId,
      pairingFilePath: pairingFilePath,
      deviceAddress: deviceAddress,
      rsdPort: rsdPort
    ) { afc in
      var logs = [
        "ARMSX2 safe boot: inspecting Automatic Load Last Game before the suspended process is allowed to run."
      ]

      for preferencePath in preferencePaths(bundleId: bundleId) {
        guard let originalData = try? readFile(afc: afc, path: preferencePath) else {
          logs.append("ARMSX2 safe boot preference file not readable: \(preferencePath)")
          continue
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(
          from: originalData,
          options: [],
          format: &format
        ) else {
          logs.append("ARMSX2 safe boot could not decode: \(preferencePath)")
          continue
        }

        var candidates = [Candidate]()
        collectCandidates(plist, components: [], displayPath: "", into: &candidates)
        candidates.sort {
          if $0.score != $1.score { return $0.score > $1.score }
          return $0.displayPath < $1.displayPath
        }

        guard let best = candidates.first, best.score >= 90 else {
          logs.append("ARMSX2 safe boot found no high-confidence AutoLoad key in \(preferencePath).")
          continue
        }

        logs.append(
          "STATE: ARMSX2_SAFE_AUTOLOAD_DETECTED key=\(best.displayPath) value=\(best.value)"
        )

        guard best.value else {
          return Armsx2AutoLoadPreferenceState(
            detectedEnabled: false,
            detectedKey: best.displayPath,
            token: nil,
            logs: logs
          )
        }

        let modified = replaceValue(
          in: plist,
          components: ArraySlice(best.components),
          with: false
        )
        let modifiedData = try PropertyListSerialization.data(
          fromPropertyList: modified,
          format: format,
          options: 0
        )
        try writeFile(afc: afc, path: preferencePath, data: modifiedData)

        // Read it back before allowing ARMSX2 to execute. If the write did not
        // stick, abort instead of risking the known ISO/Skip-BIOS race.
        let verifiedData = try readFile(afc: afc, path: preferencePath)
        var verifiedFormat = PropertyListSerialization.PropertyListFormat.binary
        let verifiedPlist = try PropertyListSerialization.propertyList(
          from: verifiedData,
          options: [],
          format: &verifiedFormat
        )
        var verifiedCandidates = [Candidate]()
        collectCandidates(
          verifiedPlist,
          components: [],
          displayPath: "",
          into: &verifiedCandidates
        )
        let verified = verifiedCandidates.first {
          $0.displayPath == best.displayPath && $0.score >= 90
        }
        guard verified?.value == false else {
          // Best effort restoration even when verification failed.
          try? writeFile(afc: afc, path: preferencePath, data: originalData)
          throw Armsx2SafeBootError.autoLoadSuppressionFailed
        }

        logs.append("STATE: ARMSX2_SAFE_AUTOLOAD_TEMP_DISABLED")
        return Armsx2AutoLoadPreferenceState(
          detectedEnabled: true,
          detectedKey: best.displayPath,
          token: Armsx2AutoLoadPreferenceToken(
            bundleId: bundleId,
            preferencePath: preferencePath,
            originalData: originalData,
            detectedKey: best.displayPath
          ),
          logs: logs
        )
      }

      logs.append("STATE: ARMSX2_SAFE_AUTOLOAD_UNAVAILABLE")
      return Armsx2AutoLoadPreferenceState(
        detectedEnabled: nil,
        detectedKey: nil,
        token: nil,
        logs: logs
      )
    }
  }

  func restore(
    _ token: Armsx2AutoLoadPreferenceToken,
    pairingFilePath: String,
    deviceAddress: String,
    rsdPort: UInt16
  ) throws {
    try withAfc(
      bundleId: token.bundleId,
      pairingFilePath: pairingFilePath,
      deviceAddress: deviceAddress,
      rsdPort: rsdPort
    ) { afc in
      try writeFile(
        afc: afc,
        path: token.preferencePath,
        data: token.originalData
      )
    }
  }

  private func preferencePaths(bundleId: String) -> [String] {
    var paths = [
      "Library/Preferences/\(bundleId).plist",
      "Library/Preferences/com.armsx2.ios.plist",
    ]
    if let suffixRange = bundleId.range(of: ".ios.") {
      let base = String(bundleId[..<suffixRange.upperBound]).dropLast()
      paths.append("Library/Preferences/\(base).plist")
    }
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }

  private func withAfc<T>(
    bundleId: String,
    pairingFilePath: String,
    deviceAddress: String,
    rsdPort: UInt16,
    body: (OpaquePointer) throws -> T
  ) throws -> T {
    var pairing: OpaquePointer?
    try check(
      pairingFilePath.withCString { pairingRead($0, &pairing) },
      fallback: "Failed to read pairing file for ARMSX2 safe boot"
    )
    guard let pairing else {
      throw Armsx2BridgeError.incompleteHandle("ARMSX2 safe-boot pairing file")
    }
    defer { pairingFree(pairing) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(rsdPort).bigEndian
    guard deviceAddress.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
      throw Armsx2BridgeError.invalidDeviceAddress(deviceAddress)
    }

    var adapter: OpaquePointer?
    var handshake: OpaquePointer?
    let tunnelError = "NeoStationARMSX2SafeBoot".withCString { hostname in
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
    try check(tunnelError, fallback: "Failed to create ARMSX2 safe-boot RSD tunnel")
    guard let adapter, let handshake else {
      throw Armsx2BridgeError.incompleteHandle("ARMSX2 safe-boot RSD tunnel")
    }
    defer {
      handshakeFree(handshake)
      adapterFree(adapter)
    }

    var houseArrest: OpaquePointer?
    try check(
      houseArrestConnect(adapter, handshake, &houseArrest),
      fallback: "Failed to connect House Arrest for ARMSX2 safe boot"
    )
    guard let houseArrest else {
      throw Armsx2BridgeError.incompleteHandle("ARMSX2 safe-boot House Arrest")
    }
    defer { houseArrestFree(houseArrest) }

    var afc: OpaquePointer?
    try check(
      bundleId.withCString { houseArrestVendContainer(houseArrest, $0, &afc) },
      fallback: "Failed to vend ARMSX2 container for safe boot"
    )
    guard let afc else {
      throw Armsx2BridgeError.incompleteHandle("ARMSX2 safe-boot AFC container")
    }
    defer { afcClientFree(afc) }

    return try body(afc)
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
      if let closeError = afcFileClose(file) { errorFree(closeError) }
    }

    var rawData: UnsafeMutablePointer<UInt8>?
    var length = 0
    try check(
      afcFileReadEntire(file, &rawData, &length),
      fallback: "Failed to read AFC file \(path)"
    )
    guard let rawData, length >= 0 else { return Data() }
    defer { afcFileReadDataFree(rawData, length) }
    return Data(bytes: rawData, count: length)
  }

  private func writeFile(afc: OpaquePointer, path: String, data: Data) throws {
    var file: OpaquePointer?
    // AfcWr (4) creates/truncates the file before writing.
    try check(
      path.withCString { afcFileOpen(afc, $0, 4, &file) },
      fallback: "Failed to open AFC file for writing \(path)"
    )
    guard let file else {
      throw Armsx2BridgeError.incompleteHandle("writable AFC file \(path)")
    }
    defer {
      if let closeError = afcFileClose(file) { errorFree(closeError) }
    }

    let writeError = data.withUnsafeBytes { rawBuffer -> OpaquePointer? in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      return afcFileWrite(file, bytes.baseAddress, data.count)
    }
    try check(writeError, fallback: "Failed to write AFC file \(path)")
  }

  private func collectCandidates(
    _ value: Any,
    components: [PathComponent],
    displayPath: String,
    into candidates: inout [Candidate]
  ) {
    if let dictionary = value as? [String: Any] {
      for (key, child) in dictionary {
        let nextDisplay = displayPath.isEmpty ? key : "\(displayPath).\(key)"
        let nextComponents = components + [.key(key)]
        if let boolValue = child as? Bool {
          candidates.append(
            Candidate(
              components: nextComponents,
              displayPath: nextDisplay,
              value: boolValue,
              score: preferenceScore(key)
            )
          )
        }
        collectCandidates(
          child,
          components: nextComponents,
          displayPath: nextDisplay,
          into: &candidates
        )
      }
      return
    }

    if let array = value as? [Any] {
      for (index, child) in array.enumerated() {
        let nextDisplay = "\(displayPath)[\(index)]"
        collectCandidates(
          child,
          components: components + [.index(index)],
          displayPath: nextDisplay,
          into: &candidates
        )
      }
    }
  }

  private func replaceValue(
    in value: Any,
    components: ArraySlice<PathComponent>,
    with newValue: Bool
  ) -> Any {
    guard let first = components.first else { return newValue }
    let remainder = components.dropFirst()

    switch first {
    case .key(let key):
      guard var dictionary = value as? [String: Any],
            let child = dictionary[key] else { return value }
      dictionary[key] = replaceValue(
        in: child,
        components: remainder,
        with: newValue
      )
      return dictionary
    case .index(let index):
      guard var array = value as? [Any], array.indices.contains(index) else {
        return value
      }
      array[index] = replaceValue(
        in: array[index],
        components: remainder,
        with: newValue
      )
      return array
    }
  }

  private func preferenceScore(_ key: String) -> Int {
    let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
    if normalized.contains("automaticloadlastgame") { return 200 }
    if normalized.contains("autoloadlastgame") { return 190 }
    if normalized.contains("loadlastgame") { return 170 }
    if normalized.contains("lastgame") && normalized.contains("autoload") { return 160 }
    if normalized.contains("lastgame") && normalized.contains("automatic") { return 150 }
    if normalized.contains("lastgame") && normalized.contains("load") { return 140 }
    if normalized.contains("skipintro") && normalized.contains("lastgame") { return 130 }
    if normalized.contains("autoload") && normalized.contains("game") { return 100 }
    if normalized.contains("lastgame") { return 70 }
    return 0
  }

  private func check(_ error: OpaquePointer?, fallback: String) throws {
    guard let error else { return }
    let record = UnsafeRawPointer(error)
      .assumingMemoryBound(to: Armsx2AutoLoadGuardErrorRecord.self)
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

enum Armsx2SafeBootError: LocalizedError {
  case autoLoadSuppressionFailed
  case autoLoadPreferenceUnavailable
  case gameURLRejected
  case gameURLTimeout

  var errorDescription: String? {
    switch self {
    case .autoLoadSuppressionFailed:
      return "ARMSX2 Automatic Load Last Game could not be disabled safely before JIT."
    case .autoLoadPreferenceUnavailable:
      return "ARMSX2 Automatic Load Last Game is enabled for direct boot, but NeoStation could not safely locate its preference before JIT."
    case .gameURLRejected:
      return "iOS rejected the ARMSX2 game URL while the JIT debugger held the target process."
    case .gameURLTimeout:
      return "Timed out while queueing the ARMSX2 game URL during JIT attach."
    }
  }
}
