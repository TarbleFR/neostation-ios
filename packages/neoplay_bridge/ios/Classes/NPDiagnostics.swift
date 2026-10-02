import Foundation

// Opt-in session diagnostics: no PINs, receiver addresses, capabilities or game paths.
enum NPLog {
    private static let queue = DispatchQueue(label: "neoplay.diagnostics", qos: .utility)
    static func record(_ event: String, _ fields: [String: Any] = [:]) {
        queue.async {
            do {
                guard let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
                let file = root.appendingPathComponent("NeoPlay.jsonl"), previous = root.appendingPathComponent("NeoPlay.jsonl.previous")
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 512 * 1024 {
                    if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                    try FileManager.default.moveItem(at: file, to: previous)
                }
                var row = fields; row["event"] = event; row["time"] = ISO8601DateFormatter().string(from: Date())
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10)
                if !FileManager.default.fileExists(atPath: file.path) { _ = FileManager.default.createFile(atPath: file.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
            } catch { /* Diagnostic I/O must never stop emulation or the stream. */ }
        }
    }
    static func error(_ event: String, _ error: Error?) {
        guard let error = error as NSError? else { record(event); return }
        // Preserve the real domain/code without leaking URL capabilities or pairing information.
        record(event, ["domain": error.domain, "code": error.code])
    }
}
