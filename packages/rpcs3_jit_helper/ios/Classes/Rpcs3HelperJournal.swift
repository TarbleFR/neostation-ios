import Foundation

/// A small journal in the extension's own container. The host cannot receive
/// TCP logs while debugserver has stopped all its threads. Record only debugger
/// boundaries here; never store pairing data, authorization tokens or ROM data.
final class Rpcs3HelperJournal {
  static let limit = 32768
  private let url: URL
  private let pid: Int32
  private let lock = NSLock()
  private var file: FileHandle?
  private var written = 0

  static func previous(in directory: URL) -> [String] {
    let files = reportFiles(in: directory)
    return files.prefix(3).compactMap { url in
      guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
      defer { try? handle.close() }
      guard let length = try? handle.seekToEnd() else { return nil }
      try? handle.seek(toOffset: length > 3500 ? length - 3500 : 0)
      guard let bytes = try? handle.read(upToCount: 3500), !bytes.isEmpty else { return nil }
      return "Previous helper journal \(url.lastPathComponent) (not current attachment proof):\n" +
        String(decoding: bytes, as: UTF8.self)
    }
  }

  init(directory: URL, targetPID: Int32) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Separate files prevent a late old helper from overwriting a new attempt.
    // Only this diagnostic directory is rotated, never any emulator/user data.
    for old in Self.reportFiles(in: directory).dropFirst(3) {
      try? FileManager.default.removeItem(at: old)
    }
    pid = targetPID
    url = directory.appendingPathComponent("host-\(targetPID)-\(UUID().uuidString).log")
    _ = FileManager.default.createFile(atPath: url.path, contents: Data())
    file = try FileHandle(forWritingTo: url)
    append("RPCS3_JOURNAL_BEGIN")
  }

  func append(_ message: String) {
    guard message.hasPrefix("RPCS3_") ||
          message.hasPrefix("NEOSTATION_RPCS3_PREPARE_") ||
          message.hasPrefix("NEOSTATION_DEBUGGER_") else { return }
    lock.lock()
    defer { lock.unlock() }
    guard let file else { return }
    let text = "\(Date().timeIntervalSince1970) pid=\(pid) \(message.prefix(1800))\n"
    let bytes = Data(text.utf8)
    do {
      if written + bytes.count > Self.limit {
        try file.truncate(atOffset: 0)
        try file.seek(toOffset: 0)
        written = 0
      }
      try file.write(contentsOf: bytes)
      written += bytes.count
    } catch {
      // Diagnostics must not decide whether JIT is available.
    }
  }

  func finishSuccessfully() {
    lock.lock()
    defer { lock.unlock() }
    try? file?.close()
    file = nil
    try? FileManager.default.removeItem(at: url)
  }

  deinit { try? file?.close() }

  private static func reportFiles(in directory: URL) -> [URL] {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles])) ?? []
    return files.filter { $0.lastPathComponent.hasPrefix("host-") && $0.pathExtension == "log" }
      .sorted {
        let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return a > b
      }
  }
}
