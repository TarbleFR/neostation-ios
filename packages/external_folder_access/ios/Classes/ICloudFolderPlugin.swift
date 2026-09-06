import Foundation
import Flutter
import UIKit
import UniformTypeIdentifiers
import CryptoKit

/// User-authorized iCloud Drive folder access, independent of app-owned iCloud
/// containers and of the team used to re-sign the IPA. No password, web login,
/// CloudKit account, guessed Mobile Documents path, or server token is used.
final class ICloudFolderPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
    private let queue = DispatchQueue(label: "neostation.icloud.files", qos: .utility)
    private let lock = NSLock()
    private var epoch = 0
    private var coordinator: NSFileCoordinator?
    private var pickerResult: FlutterResult?
    private var identityObserver: NSObjectProtocol?
    private let defaults = UserDefaults.standard
    private let fm = FileManager.default
    private let bookmarkKey = "icloud_saves.folder.v1"
    private let enabledKey = "icloud_saves.enabled.v1"
    private let scopeKey = "icloud_saves.scope.v1"
    private let identityKey = "icloud_saves.identity.v1"
    private let maxBytes: Int64 = 516 * 1024 * 1024

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = ICloudFolderPlugin()
        let channel = FlutterMethodChannel(name: "neostation/icloud_saves", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance.identityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main
        ) { [weak instance] _ in
            guard let self = instance else { return }
            self.invalidate()
            self.defaults.set(false, forKey: self.enabledKey)
            channel.invokeMethod("availabilityChanged", arguments: nil)
        }
    }

    deinit { if let observer = identityObserver { NotificationCenter.default.removeObserver(observer) } }
    private func invalidate() { lock.lock(); epoch += 1; coordinator?.cancel(); lock.unlock() }
    private func generation() -> Int { lock.lock(); defer { lock.unlock() }; return epoch }
    private func check(_ generation: Int) throws {
        if generation != self.generation() { throw failure("CANCELLED", "Save operation cancelled; local data is unchanged.") }
    }
    private func failure(_ code: String, _ message: String) -> NSError {
        NSError(domain: "iCloudSaves.\(code)", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func respond(_ result: @escaping FlutterResult, _ body: @escaping () throws -> Any?) {
        queue.async {
            do { let value = try body(); DispatchQueue.main.async { result(value) } }
            catch { let e = error as NSError; DispatchQueue.main.async {
                result(FlutterError(code: e.domain.hasPrefix("iCloudSaves.") ? String(e.domain.dropFirst(12)) : "FILE_ACCESS",
                    message: e.localizedDescription, details: nil))
            } }
        }
    }
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "connect":
            guard pickerResult == nil else { result(FlutterError(code: "BUSY", message: "A folder selection is already open.", details: nil)); return }
            guard let presenter = Self.presenter() else { result(FlutterError(code: "NO_PRESENTER", message: "Cannot open Files.", details: nil)); return }
            pickerResult = result
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.delegate = self; picker.allowsMultipleSelection = false
            presenter.present(picker, animated: true)
        case "disconnect":
            defaults.set(false, forKey: enabledKey)
            invalidate()
            respond(result) {
                self.defaults.set(false, forKey: self.enabledKey)
                for key in [self.bookmarkKey, self.scopeKey, self.identityKey] { self.defaults.removeObject(forKey: key) }
                return ["connected": false, "enabled": false]
            }
        case "setEnabled":
            if args["enabled"] as? Bool != true { defaults.set(false, forKey: enabledKey) }
            invalidate()
            respond(result) {
                let enabled = args["enabled"] as? Bool ?? false
                if enabled { _ = try self.withRoot(requireEnabled: false) { _ in true } }
                self.defaults.set(enabled, forKey: self.enabledKey)
                return try self.connection()
            }
        case "status": respond(result) { try self.connection() }
        case "list": respond(result) { try self.requireScope(args); return try self.list() }
        case "put": respond(result) { try self.put(args) }
        case "get": respond(result) { try self.get(args) }
        case "trash": respond(result) { try self.trash(args) }
        case "stageSource": respond(result) { try self.stage(args) }
        case "inspectSource": respond(result) {
            let source = URL(fileURLWithPath: try self.string(args, "source"))
            return try self.coordinate(source) { url in ["fingerprint": try self.fingerprint(url)] }
        }
        case "restoreSource": respond(result) { try self.restore(args) }
        case "recoverRestores": respond(result) { try self.recoverRestores(); return ["recovered": true] }
        default: result(FlutterMethodNotImplemented)
        }
    }
    private func requireScope(_ args: [String: Any]) throws {
        guard let expected = args["scope"] as? String, !expected.isEmpty,
              expected == defaults.string(forKey: scopeKey), defaults.bool(forKey: enabledKey) else {
            throw failure("ACCOUNT_CHANGED", "The authorized cloud folder changed. Retry after reconnecting.")
        }
    }
    private static func presenter() -> UIViewController? {
        var vc = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let result = pickerResult; pickerResult = nil; result?(nil)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let result = pickerResult else { return }; pickerResult = nil
        guard let url = urls.first else { result(nil); return }
        defaults.set(false, forKey: enabledKey)
        invalidate()
        respond(result) {
            guard url.startAccessingSecurityScopedResource() else { throw self.failure("PERMISSION", "Folder access was not granted.") }
            defer { url.stopAccessingSecurityScopedResource() }
            try self.requireICloud(url)
            let generation = self.generation()
            let saveRoot = try self.coordinate(url, write: true) { base -> URL in
                let root: URL
                if base.lastPathComponent == "Saves" && base.deletingLastPathComponent().lastPathComponent == "NeoStation" { root = base }
                else if base.lastPathComponent == "NeoStation" { root = base.appendingPathComponent("Saves", isDirectory: true) }
                else { root = base.appendingPathComponent("NeoStation/Saves", isDirectory: true) }
                try self.check(generation)
                try self.assertNoLinks(base: base, target: root)
                try self.fm.createDirectory(at: root, withIntermediateDirectories: true)
                for child in ["DolphiniOS/GameCube", "DolphiniOS/Wii"] {
                    let destination = try self.child(root, child)
                    try self.fm.createDirectory(at: destination, withIntermediateDirectories: true)
                }
                return root
            }
            let bookmark = try saveRoot.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            self.defaults.set(bookmark, forKey: self.bookmarkKey)
            self.defaults.set(UUID().uuidString, forKey: self.scopeKey)
            self.defaults.set(true, forKey: self.enabledKey)
            if let token = self.fm.ubiquityIdentityToken,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false) {
                self.defaults.set(data, forKey: self.identityKey)
            } else { self.defaults.removeObject(forKey: self.identityKey) }
            return try self.connection()
        }
    }
    private func requireICloud(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true, values.isUbiquitousItem == true else {
            throw failure("ICLOUD_REQUIRED", "Select a folder in iCloud Drive. Sign in to your Apple Account and enable iCloud Drive in Settings first.")
        }
    }
    private func withRoot<T>(requireEnabled: Bool = true, _ action: (URL) throws -> T) throws -> T {
        if requireEnabled && !defaults.bool(forKey: enabledKey) { throw failure("DISABLED", "iCloud Saves is disabled.") }
        guard let data = defaults.data(forKey: bookmarkKey) else { throw failure("NOT_CONNECTED", "Authorize an iCloud Drive folder first.") }
        // A token is a supplementary account-change signal. A nil token by
        // itself is NOT proof that a picker-authorized iCloud folder is absent.
        if let old = defaults.data(forKey: identityKey) {
            let oldToken = (try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(old)) as? NSObject
            let newToken = fm.ubiquityIdentityToken as? NSObject
            if oldToken == nil || newToken == nil || oldToken?.isEqual(newToken) != true { defaults.set(false, forKey: enabledKey); throw failure("ACCOUNT_CHANGED", "The iCloud account changed. Reconnect the save folder.") }
        }
        var stale = false
        let root = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard root.startAccessingSecurityScopedResource() else { throw failure("PERMISSION", "Reconnect the iCloud Drive folder in Files.") }
        defer { root.stopAccessingSecurityScopedResource() }
        try requireICloud(root)
        if stale {
            defaults.set(try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: bookmarkKey)
        }
        return try action(root)
    }
    private func connection() throws -> [String: Any] {
        guard defaults.data(forKey: bookmarkKey) != nil else { return ["connected": false, "enabled": false] }
        return try withRoot(requireEnabled: false) { _ in
            ["connected": true, "enabled": defaults.bool(forKey: enabledKey),
             "scope": defaults.string(forKey: scopeKey) ?? "", "folder": "iCloud Drive / NeoStation / Saves"]
        }
    }
    private func coordinate<T>(_ url: URL, write: Bool = false, _ body: (URL) throws -> T) throws -> T {
        let c = NSFileCoordinator()
        lock.lock(); coordinator = c; lock.unlock()
        defer { lock.lock(); if coordinator === c { coordinator = nil }; lock.unlock() }
        let timeout = DispatchWorkItem { c.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60, execute: timeout)
        defer { timeout.cancel() }
        var coordinationError: NSError?
        var outcome: Result<T, Error>?
        let accessor: (URL) -> Void = { target in outcome = Result { try body(target) } }
        if write { c.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError, byAccessor: accessor) }
        else { c.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor) }
        if let e = coordinationError { throw e }
        guard let result = outcome else { throw failure("PENDING", "File provider operation is pending.") }
        return try result.get()
    }
    private func child(_ root: URL, _ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, relative.count < 2048,
            !relative.contains("\\"), !relative.contains(":"),
            !relative.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw failure("INVALID_PATH", "Unsafe save path.")
        }
        let target = root.appendingPathComponent(relative)
        try assertNoLinks(base: root, target: target)
        return target
    }
    private func assertNoLinks(base: URL, target: URL) throws {
        let basePath = base.standardizedFileURL.path
        var cursor = target.standardizedFileURL
        guard cursor.path == basePath || cursor.path.hasPrefix(basePath + "/") else { throw failure("INVALID_PATH", "Save escaped its root.") }
        while true {
            if fm.fileExists(atPath: cursor.path) {
                let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true { throw failure("INVALID_PATH", "Symbolic links are not valid save paths.") }
            } else if (try? fm.destinationOfSymbolicLink(atPath: cursor.path)) != nil {
                throw failure("INVALID_PATH", "Dangling symbolic link in save path.")
            }
            if cursor.path == basePath { break }
            cursor.deleteLastPathComponent()
        }
    }
    private func locallyAvailable(_ url: URL) throws -> Bool {
        let v = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if v.isUbiquitousItem != true { return true }
        if v.ubiquitousItemDownloadingStatus == .current || v.ubiquitousItemDownloadingStatus == .downloaded { return true }
        try fm.startDownloadingUbiquitousItem(at: url)
        return false
    }
    private func transferState(_ urls: [URL]) throws -> String {
        for url in urls {
            let v = try url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
            if v.ubiquitousItemUploadingError != nil { return "error" }
            if v.ubiquitousItemIsUploaded != true { return "pending" }
        }
        return "uploaded"
    }
    private func deletionID(_ unit: String, _ contentHash: String) -> String {
        SHA256.hash(data: Data((unit + "\n" + contentHash).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func list() throws -> [String: Any] {
        let generation = self.generation()
        return try withRoot { root in
            var rows = [[String: Any]](); var pending = 0; var invalid = 0
            var deleted = [[String: Any]]()
            let deletions = try child(root, ".Deleted")
            if fm.fileExists(atPath: deletions.path) {
                let markers = try coordinate(deletions) { try self.fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.fileSizeKey]) }
                guard markers.count <= 20000 else { throw failure("LIMIT", "Too many deletion records.") }
                for marker in markers where marker.pathExtension == "json" {
                    try assertNoLinks(base: deletions, target: marker)
                    if !(try locallyAvailable(marker)) { pending += 1; continue }
                    do {
                        let row: [String: Any] = try coordinate(marker) { item in
                            guard (try item.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8192,
                                  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: item)) as? [String: Any] else { throw self.failure("MANIFEST", "Invalid deletion record.") }
                            return value
                        }
                        let unit = try string(row, "unit"), hash = try string(row, "contentHash")
                        guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                              marker.lastPathComponent == deletionID(unit, hash) + ".json" else { throw failure("MANIFEST", "Invalid deletion identity.") }
                        deleted.append(row)
                    } catch { invalid += 1 }
                }
            }
            let urls: [URL] = try coordinate(root) { base in
                var enumerationError: Error?
                guard let iterator = self.fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else { throw self.failure("PERMISSION", "Cannot enumerate iCloud saves.") }
                var found = [URL]()
                for case let url as URL in iterator {
                    try self.check(generation)
                    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                    if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
                    if url.pathExtension == "json" { found.append(url) }
                    if found.count > 20000 { throw self.failure("LIMIT", "Too many cloud save revisions.") }
                }
                if let error = enumerationError { throw error }
                return found
            }
            for url in urls {
                try check(generation)
                if !(try locallyAvailable(url)) { pending += 1; continue }
                do {
                    let json: [String: Any] = try coordinate(url) { file in
                        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 0 && size <= 32768 else { throw self.failure("MANIFEST", "Invalid save manifest size.") }
                        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { throw self.failure("MANIFEST", "Invalid manifest.") }
                        return value
                    }
                    let relative = String(url.path.dropFirst(root.path.count + 1))
                    let payload = url.deletingPathExtension().appendingPathExtension("nssave")
                    guard fm.fileExists(atPath: payload.path) else { pending += 1; continue }
                    rows.append(["manifest": json, "path": relative, "state": try transferState([payload, url])])
                } catch { invalid += 1 }
            }
            return ["revisions": rows, "pending": pending, "invalid": invalid, "deleted": deleted]
        }
    }
    private func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let s = args[key] as? String, !s.isEmpty else { throw failure("ARGUMENT", "Missing \(key).") }; return s
    }
    private func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256(); var total: Int64 = 0
        while let data = try handle.read(upToCount: 65536), !data.isEmpty {
            total += Int64(data.count); if total > maxBytes { throw failure("LIMIT", "Save exceeds size limit.") }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func privateCache() throws -> URL {
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ICloudSaves", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var excluded = base; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return base
    }
    private func put(_ args: [String: Any]) throws -> Any {
        try requireScope(args)
        let generation = self.generation()
        guard let manifest = args["manifest"] as? [String: Any], manifest["schema"] as? Int == 1 else { throw failure("MANIFEST", "Invalid manifest.") }
        let hash = try string(manifest, "payloadHash")
        guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw failure("MANIFEST", "Invalid payload digest.") }
        let source = URL(fileURLWithPath: try string(args, "source"))
        guard source.resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/") else { throw failure("SOURCE", "Publish only private verified snapshots.") }
        guard try digest(source) == hash else { throw failure("CHECKSUM", "Snapshot checksum mismatch.") }
        let relative = try string(manifest, "directory")
        let metadata = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        guard metadata.count <= 32768 else { throw failure("MANIFEST", "Manifest too large.") }
        return try withRoot { root in
            try coordinate(root, write: true) { base in
                let tombstone = try self.child(base, ".Deleted/" + self.deletionID(self.string(manifest, "unit"), self.string(manifest, "contentHash")) + ".json")
                if self.fm.fileExists(atPath: tombstone.path) { return ["state": "deleted"] }
                let dir = try self.child(base, relative)
                try self.fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let destination = try self.child(dir, hash + ".nssave")
                let metaURL = try self.child(dir, hash + ".json")
                try self.check(generation)
                if self.fm.fileExists(atPath: destination.path) {
                    guard try self.locallyAvailable(destination) else { throw self.failure("PENDING", "An existing revision is downloading.") }
                    guard try self.digest(destination) == hash else { throw self.failure("CHECKSUM", "Existing cloud revision has different bytes.") }
                } else {
                    let temporary = try self.child(dir, ".incoming-" + UUID().uuidString)
                    defer { try? self.fm.removeItem(at: temporary) }
                    try self.fm.copyItem(at: source, to: temporary)
                    guard try self.digest(temporary) == hash else { throw self.failure("CHECKSUM", "Cloud staging checksum mismatch.") }
                    try self.check(generation)
                    try self.fm.moveItem(at: temporary, to: destination)
                }
                try self.check(generation)
                if self.fm.fileExists(atPath: metaURL.path) {
                    guard try self.locallyAvailable(metaURL) else { throw self.failure("PENDING", "Revision metadata is downloading.") }
                    let existing = try self.readJSON(metaURL, limit: 32768)
                    guard NSDictionary(dictionary: existing).isEqual(to: manifest) else { throw self.failure("MANIFEST", "A different revision already occupies this path.") }
                } else { try metadata.write(to: metaURL, options: .atomic) }
                return ["state": try self.transferState([destination, metaURL])]
            }
        }
    }

    private func readJSON(_ file: URL, limit: Int = 2 * 1024 * 1024) throws -> [String: Any] {
        let size = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let length = size.fileSize, length > 0, length <= limit,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw failure("MANIFEST", "Invalid or oversized save metadata.")
        }
        return object
    }
    private func privatePath(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        guard url.resolvingSymlinksInPath().path.hasPrefix(home.path + "/") else {
            throw failure("SOURCE", "A verified private staging file is required.")
        }
        return url
    }
    private func get(_ args: [String: Any]) throws -> Any {
        try requireScope(args)
        let generation = self.generation()
        let hash = try string(args, "hash"), path = try string(args, "path")
        guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              path.hasSuffix("/" + hash + ".nssave") else { throw failure("MANIFEST", "Invalid revision path.") }
        let copy = try privateCache().appendingPathComponent("download-" + UUID().uuidString + ".nssave")
        do {
            return try withRoot { root in
                let source = try child(root, path)
                guard try locallyAvailable(source) else { throw failure("PENDING", "The save is downloading from iCloud. Retry after download.") }
                try coordinate(source) { source in
                    try self.check(generation)
                    guard try self.digest(source) == hash else { throw self.failure("CHECKSUM", "The cloud save failed its integrity check.") }
                    try self.fm.copyItem(at: source, to: copy)
                    guard try self.digest(copy) == hash else { throw self.failure("CHECKSUM", "Downloaded save failed its integrity check.") }
                    try self.check(generation)
                }
                return ["path": copy.path]
            }
        } catch { try? fm.removeItem(at: copy); throw error }
    }
    private func trash(_ args: [String: Any]) throws -> Any {
        try requireScope(args)
        let generation = self.generation()
        let id = try string(args, "id")
        return try withRoot { root in
            try coordinate(root, write: true) { root in
                let manifestURL = try self.child(root, id + ".json")
                guard try self.locallyAvailable(manifestURL) else { throw self.failure("PENDING", "Revision metadata is downloading.") }
                let manifest = try self.readJSON(manifestURL, limit: 32768)
                let hash = try self.string(manifest, "payloadHash"), unit = try self.string(manifest, "unit")
                let content = try self.string(manifest, "contentHash")
                guard id == (try self.string(manifest, "directory")) + "/" + hash,
                      hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                      content.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                    throw self.failure("MANIFEST", "Revision identity does not match its path.")
                }
                let tombstone = try self.child(root, ".Deleted/" + self.deletionID(unit, content) + ".json")
                let trash = try self.child(root, ".Trash/" + UUID().uuidString)
                try self.fm.createDirectory(at: tombstone.deletingLastPathComponent(), withIntermediateDirectories: true)
                try self.fm.createDirectory(at: trash, withIntermediateDirectories: true)
                try self.check(generation)
                // Commit removal before moving anything. Native saves are never touched.
                try JSONSerialization.data(withJSONObject: ["schema": 1, "unit": unit, "contentHash": content], options: [.sortedKeys])
                    .write(to: tombstone, options: .atomic)
                for file in [try self.child(root, id + ".nssave"), manifestURL] where self.fm.fileExists(atPath: file.path) {
                    try self.check(generation)
                    try self.fm.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent))
                }
                return ["trashed": true]
            }
        }
    }

    /// Strict native inventory, never following a symbolic link. Hashes omit
    /// timestamps so unchanged bytes do not become a new game save.
    private func nativeMembers(_ root: URL) throws -> [(URL, String, Bool)] {
        try assertNoLinks(base: root, target: root)
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        if values.isRegularFile == true {
            guard Int64(values.fileSize ?? 0) <= maxBytes else { throw failure("LIMIT", "Save is too large.") }
            return [(root, "data", false)]
        }
        guard values.isDirectory == true else { throw failure("SOURCE", "Not a native file or directory.") }
        var failureValue: Error?
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [], errorHandler: { _, error in failureValue = error; return false }) else {
            throw failure("PERMISSION", "Cannot enumerate the native save folder.")
        }
        var entries = [(URL, String, Bool)](), bytes: Int64 = 0
        for case let url as URL in iterator {
            try assertNoLinks(base: root, target: url)
            let relative = String(url.path.dropFirst(root.path.count + 1))
            _ = try child(root, relative)
            let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard v.isDirectory == true || v.isRegularFile == true else { throw failure("SOURCE", "Unsupported native save member.") }
            bytes += Int64(v.isDirectory == true ? 0 : v.fileSize ?? 0)
            entries.append((url, relative, v.isDirectory == true))
            if entries.count > 8192 || bytes > maxBytes { throw failure("LIMIT", "Native save exceeds snapshot limits.") }
        }
        if let error = failureValue { throw error }
        return entries.sorted { $0.1 < $1.1 }
    }
    private func fingerprint(_ source: URL) throws -> String {
        if !fm.fileExists(atPath: source.path) {
            try assertNoLinks(base: source, target: source)
            return "missing"
        }
        let isDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        var rows = [[String]]()
        for (file, relative, directory) in try nativeMembers(source) {
            if directory { rows.append([relative, "directory"]); continue }
            let v = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let value = try digest(file)
            let after = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard v.fileSize == after.fileSize && v.contentModificationDate == after.contentModificationDate else {
                throw failure("BUSY", "The emulator is still writing its save.")
            }
            rows.append([relative, String(v.fileSize ?? 0), value])
        }
        let bytes = try JSONSerialization.data(withJSONObject: rows)
        return (isDirectory ? "directory:" : "file:") + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func preserveModificationDates(from source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
        if values.isDirectory == true {
            for (file, relative, _) in try nativeMembers(source) {
                if let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    try fm.setAttributes([.modificationDate: date], ofItemAtPath: child(destination, relative).path)
                }
            }
        }
        if let date = values.contentModificationDate { try fm.setAttributes([.modificationDate: date], ofItemAtPath: destination.path) }
    }
    private func copyNative(_ source: URL, to destination: URL) throws {
        let before = try fingerprint(source)
        guard before != "missing", !fm.fileExists(atPath: destination.path) else { throw failure("SOURCE", "Invalid snapshot source or occupied staging path.") }
        try fm.copyItem(at: source, to: destination)
        try preserveModificationDates(from: source, to: destination)
        guard try fingerprint(source) == before, try fingerprint(destination) == before else {
            throw failure("BUSY", "Save changed while taking a snapshot; no cloud revision was published.")
        }
    }
    private func stage(_ args: [String: Any]) throws -> Any {
        let source = URL(fileURLWithPath: try string(args, "source")).standardizedFileURL
        let staging = try privateCache().appendingPathComponent("stage-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            return try coordinate(source) { source in
                let destination = staging.appendingPathComponent("data")
                try self.copyNative(source, to: destination)
                return ["path": destination.path]
            }
        } catch { try? fm.removeItem(at: staging); throw error }
    }
    private func childFingerprints(_ directory: URL) throws -> [String: String] {
        var values = [String: String]()
        for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try assertNoLinks(base: directory, target: url)
            values[url.lastPathComponent] = try fingerprint(url)
        }
        return values
    }
    private func restoreFolderContents(_ target: URL, from source: URL, generation: Int? = nil) throws {
        // The user may have granted the folder itself, not its parent. Never
        // rename that granted folder; the verified private original is retained.
        for url in try fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil) {
            try assertNoLinks(base: target, target: url)
            if let value = generation { try check(value) }
            try fm.removeItem(at: url)
        }
        for url in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            if let value = generation { try check(value) }
            try copyNative(url, to: child(target, url.lastPathComponent))
        }
        try preserveModificationDates(from: source, to: target)
    }
    private func writeJournal(_ row: [String: Any], at file: URL) throws {
        try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]).write(to: file, options: .atomic)
    }
    private func restore(_ args: [String: Any]) throws -> Any {
        try requireScope(args)
        let generation = self.generation()
        let source = try privatePath(string(args, "source"))
        let target = URL(fileURLWithPath: try string(args, "target")).standardizedFileURL
        let root = URL(fileURLWithPath: try string(args, "authorizedRoot")).standardizedFileURL
        let expected = try string(args, "expected")
        try assertNoLinks(base: root, target: target)
        let fresh = try fingerprint(source)
        guard fresh != "missing", source.path != target.path else { throw failure("SOURCE", "Restoration requires private verified save data.") }
        let transaction = try privateCache().appendingPathComponent("restore-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: transaction, withIntermediateDirectories: true)
        let original = transaction.appendingPathComponent("original")
        let replacement = transaction.appendingPathComponent("replacement")
        let journal = transaction.appendingPathComponent("journal.json")
        try copyNative(source, to: replacement)
        return try coordinate(root, write: true) { root in
            try self.assertNoLinks(base: root, target: target)
            guard try self.fingerprint(target) == expected else { throw self.failure("CONFLICT", "Local save changed. Review and confirm again.") }
            if expected != "missing" { try self.copyNative(target, to: original) }
            let wholeFolder = target.path == root.path
            guard !wholeFolder || fresh.hasPrefix("directory:") else { throw self.failure("SOURCE", "Cannot replace a granted folder with a file.") }
            let grant = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            var row: [String: Any] = ["schema": 1, "target": target.path, "root": root.path,
                "grant": grant.base64EncodedString(), "expected": expected, "replacement": fresh,
                "wholeFolder": wholeFolder, "phase": "prepared"]
            if wholeFolder {
                row["oldChildren"] = try self.childFingerprints(target)
                row["newChildren"] = try self.childFingerprints(replacement)
            }
            try self.writeJournal(row, at: journal)
            do {
                try self.check(generation)
                try self.requireScope(args)
                guard try self.fingerprint(target) == expected else { throw self.failure("CONFLICT", "Local save changed while preparing restoration.") }
                row["phase"] = "writing"; try self.writeJournal(row, at: journal)
                if wholeFolder { try self.restoreFolderContents(target, from: replacement, generation: generation) }
                else {
                    let parent = target.deletingLastPathComponent()
                    try self.assertNoLinks(base: root, target: parent)
                    try self.fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    let ready = try self.child(parent, ".ns-ready-" + UUID().uuidString)
                    let previous = try self.child(parent, ".ns-previous-" + UUID().uuidString)
                    try self.copyNative(replacement, to: ready)
                    try self.check(generation)
                    if expected != "missing" { try self.fm.moveItem(at: target, to: previous) }
                    try self.fm.moveItem(at: ready, to: target)
                    // Original remains in private recovery storage even after success.
                    if self.fm.fileExists(atPath: previous.path) { try? self.fm.removeItem(at: previous) }
                }
                guard try self.fingerprint(target) == fresh else { throw self.failure("CHECKSUM", "Restored native files do not match the selected revision.") }
                row["phase"] = "complete"; try self.writeJournal(row, at: journal)
                return ["restored": true, "backup": original.path]
            } catch {
                // Keep all evidence on any error. Recovery recognizes only known
                // old/new bytes; an unexpected concurrent change is never erased.
                throw self.failure("RECOVERY_REQUIRED", "Restoration interrupted: \(error.localizedDescription). Original data is preserved; recovery will be checked before the next save operation.")
            }
        }
    }
    private func recoverRestores() throws {
        let base = try privateCache()
        for dir in try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) where dir.lastPathComponent.hasPrefix("restore-") {
            let journal = dir.appendingPathComponent("journal.json")
            if !fm.fileExists(atPath: journal.path) { continue }
            var row = try readJSON(journal)
            if row["phase"] as? String == "complete" || row["phase"] as? String == "rolledBack" { continue }
            guard row["schema"] as? Int == 1,
                  let grant = Data(base64Encoded: try string(row, "grant")) else { throw failure("RECOVERY_REQUIRED", "Invalid restore journal; originals are preserved.") }
            var stale = false
            let root = try URL(resolvingBookmarkData: grant, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let savedRoot = URL(fileURLWithPath: try string(row, "root")).standardizedFileURL
            let savedTarget = URL(fileURLWithPath: try string(row, "target")).standardizedFileURL
            try assertNoLinks(base: savedRoot, target: savedTarget)
            let relative = String(savedTarget.path.dropFirst(savedRoot.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let target = relative.isEmpty ? root : try child(root, relative)
            let original = dir.appendingPathComponent("original")
            let expected = try string(row, "expected"), fresh = try string(row, "replacement")
            try coordinate(root, write: true) { _ in
                let actual = try self.fingerprint(target)
                if actual == fresh { row["phase"] = "complete"; try self.writeJournal(row, at: journal); return }
                if actual == expected || row["phase"] as? String == "prepared" {
                    // Prepared means no native write occurred. Preserve any
                    // external changes instead of rolling them back.
                    row["phase"] = "rolledBack"; try self.writeJournal(row, at: journal); return
                }
                guard expected != "missing", try self.fingerprint(original) == expected else {
                    throw self.failure("RECOVERY_REQUIRED", "An interrupted restore needs review. No native data was overwritten during recovery.")
                }
                if row["wholeFolder"] as? Bool == true {
                    let old = row["oldChildren"] as? [String: String] ?? [:]
                    let new = row["newChildren"] as? [String: String] ?? [:]
                    let current = try self.childFingerprints(target)
                    guard current.allSatisfy({ old[$0.key] == $0.value || new[$0.key] == $0.value }) else {
                        throw self.failure("RECOVERY_REQUIRED", "Unknown files found after interrupted restoration. Original and new revisions are preserved for review.")
                    }
                    try self.restoreFolderContents(target, from: original)
                } else {
                    guard actual == "missing" else { throw self.failure("RECOVERY_REQUIRED", "Native save changed after interrupted restoration; the original is preserved.") }
                    try self.fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try self.copyNative(original, to: target)
                }
                guard try self.fingerprint(target) == expected else { throw self.failure("RECOVERY_REQUIRED", "Original save recovery could not be verified.") }
                row["phase"] = "rolledBack"; try self.writeJournal(row, at: journal)
            }
        }
    }
}
