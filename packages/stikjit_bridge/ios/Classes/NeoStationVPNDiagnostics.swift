import Foundation

/// A local, bounded support report. Never reads pairing files, passwords,
/// emulator tokens, game files or the general application log.
enum NeoStationVPNDiagnostics {
  private static let queue = DispatchQueue(label: "neostation.vpn271.report", qos: .utility)
  private static var lastNativeStamp = ""
  private static var documents: URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
  }
  static func initialize() {
    record("session", "NeoStation VPN/RPCS3 diagnostic — build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown"); system=\(ProcessInfo.processInfo.operatingSystemVersionString); runtimeJIT=267-baseline; VPN=271")
    record("notice", "Fichier local : Diagnostic-VPN-RPCS3.txt. Retour arriere du lancement RPCS3; commandes VPN bornees. Aucun pairing file, mot de passe ou jeton collecte. VPN conserve pendant la suspension du frontend; arret explicite toujours disponible.")
    snapshotRPCS3()
  }
  static func record(_ stage: String, _ message: String) {
    let time = ISO8601DateFormatter().string(from: Date())
    let text = "\(time) [\(stage)] \(scrub(message))\n"
    queue.async { append(text) }
  }
  static func scrub(_ value: String) -> String {
    var result = String(value.prefix(1600)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    for pattern in [
      #"(?i)(token|password|api[_ -]?key|authorization|username|hostid|systembuid|udid|pairing(?:file)?)\s*[:=]\s*[^;,\s]+"#,
      #"/(?:private/)?var/[^\s;,]+"#,
      #"(?i)https?://[^\s;,]+"#
    ] {
      guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
      result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]")
    }
    return result
  }
  private static func append(_ text: String) {
    guard let documents else { return }
    let path = documents.appendingPathComponent("Diagnostic-VPN-RPCS3.txt")
    let files = FileManager.default
    do {
      try files.createDirectory(at: documents, withIntermediateDirectories: true)
      let size = (try? files.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.intValue ?? 0
      if size > 512 * 1024 {
        let previous = documents.appendingPathComponent("Diagnostic-VPN-RPCS3-precedent.txt")
        try? files.removeItem(at: previous); try files.moveItem(at: path, to: previous)
      }
      if !files.fileExists(atPath: path.path) { _ = files.createFile(atPath: path.path, contents: Data()) }
      let file = try FileHandle(forWritingTo: path)
      defer { try? file.close() }
      try file.seekToEnd(); try file.write(contentsOf: Data(text.utf8)); try file.synchronize()
    } catch {
      // Diagnostics must not fail a VPN or JIT operation.
    }
  }
  static func snapshotRPCS3() {
    queue.async {
      guard let documents else { return }
      let diagnosticStages: Set<String> = [
        "memory_preflight_begin", "memory_preflight_end",
      ]
      let milestoneStages: Set<String> = [
        "jit_prepare_begin", "jit_helper_connected", "jit_debugger_attached",
        "jit_prepare_ready", "jit_prepare_failed", "debugger_probe_begin",
        "debugger_probe_end", "core_handoff_begin", "core_handoff_end",
        "core_load_begin", "core_load_end", "core_initialize_begin",
        "core_initialize_end", "jit_completion_begin", "jit_completion_end",
        "llvm_self_test_begin", "llvm_self_test_end", "game_boot_begin",
        "game_boot_return",
      ]
      func readStages(_ name: String, _ accepted: Set<String>) -> [(Double, String)] {
        let path = documents.appendingPathComponent(name)
        guard let file = try? FileHandle(forReadingFrom: path) else { return [] }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return [] }
        try? file.seek(toOffset: size > 131072 ? size - 131072 : 0)
        guard let bytes = try? file.read(upToCount: 131072) else { return [] }
        var rows = [(Double, String)]()
        for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
          guard let decoded = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let stage = decoded["stage"] as? String, accepted.contains(stage),
                let time = decoded["timestamp"] as? NSNumber else { continue }
          // Stage and timestamp only: no user-supplied names or native payload.
          rows.append((time.doubleValue, "native time=\(time) stage=\(stage)"))
        }
        return rows
      }
      let rows = (
        readStages("RPCS3-diagnostic.log", diagnosticStages) +
        readStages("RPCS3-milestones.log", milestoneStages)
      ).sorted { $0.0 < $1.0 }.map { $0.1 }
      guard let last = rows.last, last != lastNativeStamp else { return }
      lastNativeStamp = last
      append("--- RPCS3 : derniers jalons natifs recuperes, pas une preuve de la cause du crash ---\n" + rows.suffix(20).joined(separator: "\n") + "\n")
    }
  }
}
