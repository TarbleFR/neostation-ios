import Flutter
import UIKit
import UniformTypeIdentifiers
import AVFoundation
import CryptoKit

/// Lets NeoStation pick a folder exposed by another app (e.g. RetroArch,
/// which shows up under "On My iPhone > RetroArch" in the Files app) via
/// the system document picker, and keeps that access valid across app
/// relaunches using a security-scoped bookmark.
///
/// Why this exists: iOS sandboxes every app from every other app's storage.
/// A path picked via UIDocumentPickerViewController is only guaranteed
/// accessible for the picking session unless you persist a *security-scoped
/// bookmark* and re-resolve + re-activate it (startAccessingSecurityScopedResource)
/// on every subsequent launch. That's exactly what this plugin does, so
/// NeoStation can scan RetroArch's own ROM folder in place instead of
/// copying files into its own sandbox.
public class ExternalFolderAccessPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate,
    UIDocumentInteractionControllerDelegate
{
    private var pendingResult: FlutterResult?
    private var channel: FlutterMethodChannel?
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var audioSessionKnownActive = false

    /// Bookmarks are stored per-emulator so several external folders can be
    /// linked side by side (RetroArch's, ARMSX2's, ...) instead of the one
    /// global slot this plugin originally had. The historical key is reused
    /// verbatim for the "retroarch" bookmark, so a folder linked before
    /// multi-bookmark support survives the upgrade with no migration step.
    private static let legacyBookmarkDefaultsKey = "external_folder_access.bookmark"
    private static let defaultBookmarkKey = "retroarch"

    /// The bookmark key the in-flight document picker will store under.
    /// Captured when the pick starts because UIDocumentPickerDelegate's
    /// callback carries no context of its own.
    private var pendingBookmarkKey: String = ExternalFolderAccessPlugin.defaultBookmarkKey

    private static func bookmarkDefaultsKey(for key: String) -> String {
        return key == defaultBookmarkKey
            ? legacyBookmarkDefaultsKey
            : "\(legacyBookmarkDefaultsKey).\(key)"
    }

    /// Reads the optional "key" argument, falling back to the default so a
    /// call made without one behaves exactly as it did before.
    private static func bookmarkKey(from call: FlutterMethodCall) -> String {
        guard let args = call.arguments as? [String: Any],
            let key = args["key"] as? String,
            !key.isEmpty
        else {
            return defaultBookmarkKey
        }
        return key
    }

    // Held as a property, not a local var — UIDocumentInteractionController
    // must stay alive for the duration of its menu/preview, and a local
    // variable would be deallocated the moment the calling function returns.
    private var documentInteractionController: UIDocumentInteractionController?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "neostation/external_folder_access",
            binaryMessenger: registrar.messenger()
        )
        let instance = ExternalFolderAccessPlugin()
        instance.channel = channel
        instance.installAudioSessionObservers()
        registrar.addMethodCallDelegate(instance, channel: channel)
        // Lets this plugin receive application(_:open:options:) callbacks —
        // needed to catch RetroArch calling back into neostation://... See
        // the method below and RetroArchLibraryService on the Dart side.
        registrar.addApplicationDelegate(instance)
    }

    /// Called by iOS when another app (or Safari) opens a URL registered to
    /// this app's CFBundleURLTypes — specifically, RetroArch's library
    /// export protocol calling back via
    /// neostation://retroarch?games=<base64url>. Forwards the URL to Dart
    /// as a method call on the same channel, rather than pulling in the
    /// third-party app_links package for what's otherwise a single simple
    /// callback.
    public func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        channel?.invokeMethod("onIncomingUrl", arguments: url.absoluteString)
        return true
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "pickAndBookmarkFolder":
            pickFolder(key: Self.bookmarkKey(from: call), result: result)
        case "resolveBookmarkedFolder":
            resolveBookmarkedFolder(key: Self.bookmarkKey(from: call), result: result)
        case "clearBookmark":
            clearBookmark(key: Self.bookmarkKey(from: call), result: result)
        case "openInMenu":
            openInMenu(call: call, result: result)
        case "openRawUrl":
            openRawUrl(call: call, result: result)
        case "configureAudioSessionForSilentMode":
            configureAudioSessionForSilentMode(result: result)
        case "openJitRequest":
            openJitRequest(call: call, result: result)
        case "sha256File":
            sha256File(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Hashes large ROM images off the main thread. Doing this in Dart made
    /// multi-gigabyte 3DS games leave NeoStation on its launch overlay.
    private func sha256File(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard
            let args = call.arguments as? [String: Any],
            let filePath = args["path"] as? String,
            !filePath.isEmpty
        else {
            result(FlutterError(code: "INVALID_PATH", message: "Missing file path", details: nil))
            return
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
                defer { handle.closeFile() }
                var hasher = SHA256()
                while true {
                    let data = handle.readData(ofLength: 1024 * 1024)
                    if data.isEmpty { break }
                    hasher.update(data: data)
                }
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                DispatchQueue.main.async { result(digest) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "HASH_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    // MARK: - Pick

    private func pickFolder(key: String, result: @escaping FlutterResult) {
        guard let rootVC = Self.topViewController() else {
            result(
                FlutterError(
                    code: "NO_ROOT_VC",
                    message: "No root view controller available to present the picker from",
                    details: nil
                )
            )
            return
        }

        // A previous pick that never got a callback (e.g. the app was
        // killed mid-pick) shouldn't leak a dangling result — just drop it
        // rather than trying to call it twice.
        pendingResult = result
        pendingBookmarkKey = key

        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        } else {
            picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
        }
        picker.delegate = self
        picker.allowsMultipleSelection = false

        rootVC.present(picker, animated: true, completion: nil)
    }

    public func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else {
            pendingResult?(nil)
            pendingResult = nil
            return
        }

        // Bookmark creation itself needs the resource to be accessible;
        // wrap it in a matched start/stop pair even though the picker's
        // returned URL is already scoped for this immediate callback.
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(
                bookmarkData,
                forKey: Self.bookmarkDefaultsKey(for: pendingBookmarkKey)
            )
            pendingResult?(url.path)
        } catch {
            pendingResult?(
                FlutterError(
                    code: "BOOKMARK_FAILED",
                    message: error.localizedDescription,
                    details: nil
                )
            )
        }
        pendingResult = nil
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingResult?(nil)
        pendingResult = nil
    }

    // MARK: - Resolve / clear

    /// Resolves the previously-bookmarked folder (if any) and starts
    /// security-scoped access for the remainder of this app session.
    /// Deliberately never calls stopAccessingSecurityScopedResource() here —
    /// NeoStation needs the folder readable for as long as the app runs, and
    /// iOS releases the scope automatically when the process exits.
    private func resolveBookmarkedFolder(key: String, result: @escaping FlutterResult) {
        guard
            let bookmarkData = UserDefaults.standard.data(
                forKey: Self.bookmarkDefaultsKey(for: key)
            )
        else {
            result(nil)
            return
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else {
                result(
                    FlutterError(
                        code: "ACCESS_DENIED",
                        message: "startAccessingSecurityScopedResource returned false",
                        details: nil
                    )
                )
                return
            }

            // Sideload updates/re-signing can make an otherwise resolvable
            // bookmark stale. Refresh it immediately while the security scope
            // is active so subsequent cold launches keep the same folder grant.
            if isStale {
                do {
                    let refreshedBookmark = try url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    UserDefaults.standard.set(
                        refreshedBookmark,
                        forKey: Self.bookmarkDefaultsKey(for: key)
                    )
                } catch {
                    // The currently resolved URL is still usable for this
                    // process. Keep it rather than failing the whole launch;
                    // the next relink can replace the bookmark if necessary.
                    print("ExternalFolderAccess: failed refreshing stale bookmark for \(key): \(error)")
                }
            }
            result(url.path)
        } catch {
            result(
                FlutterError(
                    code: "RESOLVE_FAILED",
                    message: error.localizedDescription,
                    details: nil
                )
            )
        }
    }

    private func clearBookmark(key: String, result: @escaping FlutterResult) {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkDefaultsKey(for: key))
        result(nil)
    }

    // MARK: - iOS audio session

    /// Registers infrequent structural recovery hooks. Normal player
    /// starts, pauses, volume changes and disposals never touch
    /// AVAudioSession.
    private func installAudioSessionObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        audioSessionObservers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                guard
                    let number = notification.userInfo?[
                        AVAudioSessionInterruptionTypeKey
                    ] as? NSNumber,
                    let type = AVAudioSession.InterruptionType(
                        rawValue: number.uintValue
                    )
                else {
                    return
                }

                switch type {
                case .began:
                    self.audioSessionKnownActive = false
                case .ended:
                    try? self.applySilentModeAudioSession(
                        forceActivation: true
                    )
                @unknown default:
                    break
                }
            }
        )

        audioSessionObservers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                try? self.applySilentModeAudioSession(
                    forceActivation: false
                )
            }
        )
    }

    deinit {
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Applies NeoStation's one app-wide audio policy.
    ///
    /// Category writes are skipped when the session is already correct.
    /// Activation is forced only at startup, application resume, shared
    /// SoLoud engine creation, or interruption end.
    @discardableResult
    private func applySilentModeAudioSession(
        forceActivation: Bool
    ) throws -> Bool {
        let session = AVAudioSession.sharedInstance()
        let desiredOptions: AVAudioSession.CategoryOptions = [
            .mixWithOthers
        ]
        let categoryNeedsUpdate =
            session.category != .ambient ||
            session.mode != .default ||
            session.categoryOptions != desiredOptions

        if categoryNeedsUpdate {
            try session.setCategory(
                .ambient,
                mode: .default,
                options: desiredOptions
            )
        }

        if forceActivation || !audioSessionKnownActive {
            try session.setActive(true)
            audioSessionKnownActive = true
        }
        return true
    }

    private func configureAudioSessionForSilentMode(
        result: @escaping FlutterResult
    ) {
        do {
            result(
                try applySilentModeAudioSession(
                    forceActivation: true
                )
            )
        } catch {
            result(
                FlutterError(
                    code: "AUDIO_SESSION_FAILED",
                    message: error.localizedDescription,
                    details: nil
                )
            )
        }
    }

    // MARK: - Raw URL opening

    /// Opens a custom URL exactly as supplied by Dart. Unlike constructing a
    /// Dart Uri first, this preserves the original case of the authority/host
    /// text. MeloNX currently dispatches `gameInfo` case-sensitively.
    private func openRawUrl(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let raw = args["url"] as? String,
            !raw.isEmpty,
            let url = URL(string: raw)
        else {
            result(
                FlutterError(
                    code: "INVALID_URL",
                    message: "openRawUrl requires a valid 'url' string argument",
                    details: nil
                )
            )
            return
        }

        UIApplication.shared.open(url, options: [:]) { opened in
            result(opened)
        }
    }

    // MARK: - Immediate StikDebug request

    private func openJitRequest(
        call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        guard let args = call.arguments as? [String: Any],
            let targetBaseBundleId = args["targetBaseBundleId"] as? String,
            !targetBaseBundleId.isEmpty
        else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "openJitRequest requires targetBaseBundleId",
                details: nil
            ))
            return
        }

        let scriptName = ((args["scriptName"] as? String) ?? "universal.js")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let debugFileName = Self.safeDebugFileName(
            (args["debugFileName"] as? String) ?? "jit_request_debug.txt"
        )
        let suffix = Self.currentSideloadBundleSuffix()
        let targetBundleId = (suffix?.isEmpty == false)
            ? "\(targetBaseBundleId).\(suffix!)"
            : targetBaseBundleId

        var components = URLComponents()
        components.scheme = "stikjit"
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: targetBundleId),
            URLQueryItem(name: "script-name", value: scriptName),
        ]
        if let scriptData = args["scriptData"] as? String,
            !scriptData.isEmpty
        {
            components.queryItems?.append(
                URLQueryItem(name: "script-data", value: scriptData)
            )
        }

        guard let url = components.url else {
            result(FlutterError(
                code: "INVALID_JIT_URL",
                message: "Could not build StikDebug request URL",
                details: nil
            ))
            return
        }

        Self.writeLaunchDebug(
            fileName: debugFileName,
            replace: true,
            message: "STATE: JIT_REQUEST\n"
                + "Application state: \(Self.applicationStateName())\n"
                + "Target base bundle: \(targetBaseBundleId)\n"
                + "Target effective bundle: \(targetBundleId)\n"
                + "Script: \(scriptName)\n"
                + "URL: \(url.absoluteString)"
        )

        UIApplication.shared.open(url, options: [:]) { opened in
            Self.writeLaunchDebug(
                fileName: debugFileName,
                replace: false,
                message: opened ? "STATE: JIT_REQUEST_OPENED" : "STATE: JIT_REQUEST_FAILED"
            )
            result(opened)
        }
    }

    /// Returns the suffix SideStore/AltStore appended to NeoStation's original
    /// bundle identifier, if any. Example:
    ///   com.neogamelab.neostation.ABC123
    /// becomes:
    ///   ABC123
    /// The same suffix can then be applied to the official emulator bundle ID.
    private static func currentSideloadBundleSuffix() -> String? {
        let baseBundleId = "com.neogamelab.neostation"
        guard let currentBundleId = Bundle.main.bundleIdentifier,
            !currentBundleId.isEmpty,
            currentBundleId != baseBundleId
        else {
            return nil
        }

        let prefix = "\(baseBundleId)."
        guard currentBundleId.hasPrefix(prefix) else {
            return nil
        }

        let suffix = String(currentBundleId.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }

    private static func safeDebugFileName(_ value: String) -> String {
        let candidate = URL(fileURLWithPath: value).lastPathComponent
        return candidate.isEmpty ? "jit_launch_debug.txt" : candidate
    }

    private static func writeLaunchDebug(
        fileName: String,
        replace: Bool,
        message: String
    ) {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return }

        let fileURL = documents.appendingPathComponent(fileName)
        let line = "--- \(ISO8601DateFormatter().string(from: Date())) ---\n\(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            if replace || !FileManager.default.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
        } catch {
            // Diagnostics must never interfere with launching a game.
        }
    }

    // MARK: - Open In

    /// Presents iOS's genuine "Open In" menu for a file — a different API
    /// from the general Share Sheet (UIActivityViewController, used
    /// elsewhere via the share_plus package). "Open In" specifically hands
    /// the file to an app that declared itself able to *own*/import that
    /// document type, which is the traditional "here's a file, please open
    /// it" flow — distinct from "here's some content, do something with
    /// it" (sharing). Whether RetroArch actually treats these two
    /// differently (e.g. jumping straight into a game it already
    /// recognizes vs. re-importing) is exactly what this exists to test.
    private func openInMenu(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let filePath = args["path"] as? String
        else {
            result(
                FlutterError(
                    code: "INVALID_ARGS",
                    message: "openInMenu requires a 'path' string argument",
                    details: nil
                )
            )
            return
        }

        guard let rootVC = Self.topViewController(), let view = rootVC.view else {
            result(
                FlutterError(
                    code: "NO_ROOT_VC",
                    message: "No root view controller available to present the menu from",
                    details: nil
                )
            )
            return
        }

        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            result(
                FlutterError(
                    code: "FILE_NOT_FOUND",
                    message: "No file at \(filePath)",
                    details: nil
                )
            )
            return
        }

        let controller = UIDocumentInteractionController(url: fileURL)
        controller.delegate = self
        documentInteractionController = controller

        // Centered rect as a reasonable default anchor for the iPad
        // popover; exact position doesn't affect whether an app can open
        // the file, only where the menu visually appears from.
        let anchorRect = CGRect(
            x: view.bounds.midX - 1,
            y: view.bounds.midY - 1,
            width: 2,
            height: 2
        )

        let didPresent = controller.presentOpenInMenu(
            from: anchorRect,
            in: view,
            animated: true
        )
        result(didPresent)
    }

    // MARK: - Helpers

    private static func topViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }

        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
