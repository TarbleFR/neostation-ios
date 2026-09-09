import Foundation
import Network
import StikJIT

private let dolphinRequestType = "com.neogamelab.neostation.dolphin-jit-request"

/// Dedicated helper: NeoStation is the target; no other emulator is attached.
@available(iOS 17.4, *)
open class DolphinJITRequestHandlerBase: NSObject, NSExtensionRequestHandling {
  private let jitQueue = DispatchQueue(label: "com.neogamelab.neostation.dolphin.jit-helper", qos: .userInitiated)

  public override init() { super.init() }

  open func beginRequest(with context: NSExtensionContext) {
    guard let item = context.inputItems.first as? NSExtensionItem,
          let provider = item.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(dolphinRequestType) }) else {
      context.cancelRequest(withError: HelperError.invalidRequest("Missing Dolphin JIT request payload."))
      return
    }
    provider.loadItem(forTypeIdentifier: dolphinRequestType, options: nil) { [weak self] item, error in
      guard let self else { return }
      if let error { context.cancelRequest(withError: error); return }
      let data: Data?
      if let item = item as? Data { data = item }
      else if let item = item as? NSData { data = item as Data }
      else if let url = item as? URL { data = try? Data(contentsOf: url) }
      else { data = nil }
      guard let data else {
        context.cancelRequest(withError: HelperError.invalidRequest("Unreadable Dolphin JIT request payload."))
        return
      }
      self.jitQueue.async { self.process(data: data, context: context) }
    }
  }

  private func process(data: Data, context: NSExtensionContext) {
    var reporter: HelperReporter?
    var temporaryPairingURL: URL?
    do {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            (object["protocolVersion"] as? NSNumber)?.intValue == 1,
            let targetPIDNumber = object["targetPID"] as? NSNumber,
            targetPIDNumber.int32Value > 0,
            let portNumber = object["port"] as? NSNumber,
            portNumber.intValue > 0, portNumber.intValue <= 65535,
            let token = object["token"] as? String, !token.isEmpty,
            let pairingBase64 = object["pairingData"] as? String,
            let pairingData = Data(base64Encoded: pairingBase64),
            (128...(5 * 1024 * 1024)).contains(pairingData.count) else {
        throw HelperError.invalidRequest("Invalid Dolphin JIT request fields.")
      }
      let targetPID = targetPIDNumber.int32Value
      reporter = try HelperReporter(port: portNumber.uint16Value, token: token)
      try reporter?.connect()
      try reporter?.send(event: "helper_connected", message: "Dolphin JIT helper connected to NeoStation.")
      try reporter?.send(event: "log", message: "Preparing StikJIT 1.5.0 for NeoStation PID \(targetPID).")
      let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NeoStationDolphinJIT", isDirectory: true)
      try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
      let pairingURL = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("plist")
      try pairingData.write(to: pairingURL, options: [.atomic, .completeFileProtection])
      temporaryPairingURL = pairingURL
      let library = try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let stikRoot = library.appendingPathComponent("NeoStationDolphinStikJIT", isDirectory: true)
      try FileManager.default.createDirectory(at: stikRoot, withIntermediateDirectories: true)
      let configuration = StikJIT.Configuration.default
      let ddiPaths = DDIPaths.default(in: stikRoot)
      try reporter?.send(event: "log", message: "Starting StikJIT with the developer-locked legacy script.")
      try StikJIT.enableJIT(
        targetPID: targetPID,
        pairingFile: pairingURL,
        ddiPaths: ddiPaths,
        configuration: configuration,
        script: .legacy,
        forceScript: true,
        preparationProgress: { stage in
          try? reporter?.send(event: "log", message: Self.preparationDescription(stage))
        },
        progress: { message in
          try? reporter?.send(event: "log", message: message)
          if Self.successfulAttachReply(message) {
            try? reporter?.send(event: "pid_attached", message: "Fresh legacy vAttach stop reply received.", targetPID: targetPID)
          }
        }
      )
      try reporter?.send(event: "complete", message: "StikJIT completed the Dolphin legacy transaction and detached.", success: true)
      if let temporaryPairingURL { try? FileManager.default.removeItem(at: temporaryPairingURL) }
      reporter?.close()
      context.completeRequest(returningItems: nil)
    } catch {
      try? reporter?.send(event: "complete", message: error.localizedDescription, success: false)
      if let temporaryPairingURL { try? FileManager.default.removeItem(at: temporaryPairingURL) }
      reporter?.close()
      context.cancelRequest(withError: error)
    }
  }

  // CS_DEBUGGED survives detachment. It is never accepted as fresh evidence.
  // This log record is emitted by the actual pinned legacy.js vAttach request.
  private static func successfulAttachReply(_ message: String) -> Bool {
    guard let marker = message.range(of: "attach_response = ") else { return false }
    let reply = message[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard reply.count >= 3, reply.first == "T" else { return false }
    return reply.dropFirst().prefix(2).allSatisfy { $0.isHexDigit }
  }

  private static func preparationDescription(_ stage: StikJIT.PreparationStage) -> String {
    switch stage {
    case .checkingReachability: return "StikJIT: checking LocalDevVPN/RSD reachability."
    case .checkingDDI: return "StikJIT: checking the Developer Disk Image."
    case .downloadingDDI(let fraction, let status): return "StikJIT: DDI download \(Int(fraction * 100))% — \(status)"
    case .mountingDDI(let fraction): return "StikJIT: mounting DDI \(Int(fraction * 100))%."
    case .verifyingDDI: return "StikJIT: verifying the mounted DDI."
    case .ready: return "StikJIT: device ready; attaching legacy.js to NeoStation."
    @unknown default: return "StikJIT: unknown preparation stage."
    }
  }
}

private final class HelperReporter {
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "com.neogamelab.neostation.dolphin.jit-helper-reporter")
  private let token: String
  private let sendLock = NSLock()
  private var started = false
  init(port: UInt16, token: String) throws {
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw HelperError.invalidRequest("Invalid NeoStation helper port.") }
    self.token = token
    connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: endpointPort, using: .tcp)
  }
  func connect() throws {
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var connectionError: Error?
    var isReady = false
    connection.stateUpdateHandler = { state in
      lock.lock(); defer { lock.unlock() }
      switch state {
      case .ready: isReady = true; semaphore.signal()
      case .failed(let error), .waiting(let error): connectionError = error; semaphore.signal()
      default: break
      }
    }
    connection.start(queue: queue)
    started = true
    guard semaphore.wait(timeout: .now() + 20) == .success else { throw HelperError.connection("Timed out connecting to NeoStation.") }
    lock.lock(); defer { lock.unlock() }
    if let connectionError { throw connectionError }
    if !isReady { throw HelperError.connection("NeoStation helper socket did not become ready.") }
  }
  func send(event: String, message: String, success: Bool? = nil, targetPID: Int32? = nil) throws {
    sendLock.lock(); defer { sendLock.unlock() }
    var payload: [String: Any] = ["token": token, "event": event, "message": message]
    if let success { payload["success"] = success }
    if let targetPID { payload["targetPID"] = targetPID }
    var data = try JSONSerialization.data(withJSONObject: payload)
    data.append(0x0A)
    let semaphore = DispatchSemaphore(value: 0)
    var sendError: Error?
    connection.send(content: data, completion: .contentProcessed { error in
      sendError = error; semaphore.signal()
    })
    guard semaphore.wait(timeout: .now() + 20) == .success else { throw HelperError.connection("Timed out writing to NeoStation.") }
    if let sendError { throw sendError }
  }
  func close() { if started { connection.cancel() }; started = false }
}

private enum HelperError: LocalizedError {
  case invalidRequest(String)
  case connection(String)
  var errorDescription: String? {
    switch self {
    case .invalidRequest(let message), .connection(let message): return message
    }
  }
}
