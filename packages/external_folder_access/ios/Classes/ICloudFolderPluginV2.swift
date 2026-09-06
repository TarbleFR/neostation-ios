import Foundation
import Flutter
import UIKit
import UniformTypeIdentifiers

/// Hardened authorization front-end for iCloud Saves.
///
/// The save transport/restoration implementation remains in ICloudFolderPlugin;
/// this class only fixes account detection and the folder-authorization flow.
/// It intentionally keeps user-picked iCloud Drive access instead of requiring
/// an app-owned ubiquity container, so re-signed/sideloaded IPA installs keep a
/// viable authorization path.
final class ICloudFolderPluginV2: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
    private let legacy = ICloudFolderPlugin()
    private let fm = FileManager.default
    private let defaults = UserDefaults.standard
    private let bookmarkKey = "icloud_saves.folder.v1"
    private let enabledKey = "icloud_saves.enabled.v1"
    private let scopeKey = "icloud_saves.scope.v1"
    private let identityKey = "icloud_saves.identity.v1"
    private var pickerResult: FlutterResult?
    private weak var pickerController: UIDocumentPickerViewController?
    private var identityObserver: NSObjectProtocol?
    private var channel: FlutterMethodChannel?

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = ICloudFolderPluginV2()
        let channel = FlutterMethodChannel(
            name: "neostation/icloud_saves_v2",
            binaryMessenger: registrar.messenger()
        )
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance.identityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak instance] _ in
            guard let self = instance else { return }
            self.defaults.set(false, forKey: self.enabledKey)
            self.channel?.invokeMethod("availabilityChanged", arguments: nil)
        }
    }

    deinit {
        if let observer = identityObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "connect":
            beginAuthorization(result)
        case "status":
            legacy.handle(call) { [weak self] value in
                guard let self else { result(value); return }
                if var status = value as? [String: Any] {
                    let accountAvailable = self.fm.ubiquityIdentityToken != nil
                    status["accountAvailable"] = accountAvailable
                    status["accountDetection"] = accountAvailable ? "detected" : "not_detected"
                    result(status)
                } else {
                    result(value)
                }
            }
        default:
            legacy.handle(call, result: result)
        }
    }

    private func beginAuthorization(_ result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            guard self.pickerResult == nil else {
                result(FlutterError(code: "BUSY", message: "An iCloud folder selection is already open.", details: nil))
                return
            }
            self.pickerResult = result
            self.presentPicker(attempt: 0)
        }
    }

    private func presentPicker(attempt: Int) {
        guard pickerResult != nil else { return }
        guard let presenter = Self.presenter() else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    self.presentPicker(attempt: attempt + 1)
                }
            } else {
                finishPickerError("NO_PRESENTER", "Cannot open Files to authorize iCloud Drive.")
            }
            return
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .formSheet
        pickerController = picker
        presenter.present(picker, animated: true)

        // UIKit can reject a presentation while another transition is
        // completing without invoking our document-picker delegate. Never let
        // the Flutter Future stay pending forever in that case.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak picker] in
            guard let self, self.pickerResult != nil, let picker else { return }
            if picker.presentingViewController == nil && picker.viewIfLoaded?.window == nil {
                self.pickerController = nil
                if attempt < 20 {
                    self.presentPicker(attempt: attempt + 1)
                } else {
                    self.finishPickerError("PRESENTATION_FAILED", "Files could not be presented. Try again.")
                }
            }
        }
    }

    private static func presenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.sorted {
            ($0.activationState == .foregroundActive ? 0 : 1) <
            ($1.activationState == .foregroundActive ? 0 : 1)
        }
        let windows = ordered.flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ??
                windows.first(where: { !$0.isHidden && $0.alpha > 0 && $0.windowLevel == .normal }),
              var controller = window.rootViewController else {
            return nil
        }
        while let presented = controller.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        guard !controller.isBeingDismissed,
              controller.viewIfLoaded?.window != nil else {
            return nil
        }
        return controller
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let result = pickerResult
        pickerResult = nil
        pickerController = nil
        result?(nil)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let result = pickerResult else { return }
        pickerResult = nil
        pickerController = nil
        guard let selected = urls.first else { result(nil); return }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let status = try self.authorize(selected)
                DispatchQueue.main.async { result(status) }
            } catch {
                let e = error as NSError
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: e.domain.hasPrefix("iCloudSavesV2.") ? String(e.domain.dropFirst(14)) : "FILE_ACCESS",
                        message: e.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    private func authorize(_ selected: URL) throws -> [String: Any] {
        guard selected.startAccessingSecurityScopedResource() else {
            throw failure("PERMISSION", "Folder access was not granted.")
        }
        defer { selected.stopAccessingSecurityScopedResource() }
        try requireICloud(selected)

        var coordinationError: NSError?
        var outcome: Result<URL, Error>?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: selected, options: .forMerging, error: &coordinationError) { base in
            outcome = Result {
                try self.requireICloud(base)
                let root: URL
                if base.lastPathComponent == "Saves" && base.deletingLastPathComponent().lastPathComponent == "NeoStation" {
                    root = base
                } else if base.lastPathComponent == "NeoStation" {
                    root = base.appendingPathComponent("Saves", isDirectory: true)
                } else {
                    root = base.appendingPathComponent("NeoStation/Saves", isDirectory: true)
                }
                try self.fm.createDirectory(at: root, withIntermediateDirectories: true)
                for relative in [
                    "DolphiniOS/GameCube",
                    "DolphiniOS/Wii",
                    "ARMSX2/PS2",
                    "MeloNX/Switch",
                    "RPCS3/PS3",
                    "RetroArch"
                ] {
                    try self.fm.createDirectory(
                        at: root.appendingPathComponent(relative, isDirectory: true),
                        withIntermediateDirectories: true
                    )
                }
                return root
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw failure("PENDING", "iCloud Drive did not finish creating the Saves folder.") }
        let saveRoot = try outcome.get()

        let bookmark = try saveRoot.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try verifyBookmark(bookmark)

        let scope = UUID().uuidString
        defaults.set(bookmark, forKey: bookmarkKey)
        defaults.set(scope, forKey: scopeKey)
        defaults.set(true, forKey: enabledKey)
        if let token = fm.ubiquityIdentityToken,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false) {
            defaults.set(data, forKey: identityKey)
        } else {
            defaults.removeObject(forKey: identityKey)
        }

        let accountAvailable = fm.ubiquityIdentityToken != nil
        return [
            "connected": true,
            "enabled": true,
            "scope": scope,
            "folder": "iCloud Drive / NeoStation / Saves",
            "accountAvailable": accountAvailable,
            "accountDetection": accountAvailable ? "detected" : "not_detected"
        ]
    }

    private func verifyBookmark(_ data: Data) throws {
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: data,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard resolved.startAccessingSecurityScopedResource() else {
            throw failure("PERMISSION", "The iCloud Saves folder permission could not be persisted.")
        }
        resolved.stopAccessingSecurityScopedResource()
    }

    private func requireICloud(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isUbiquitousItemKey,
            .isSymbolicLinkKey
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isUbiquitousItem == true else {
            throw failure(
                "ICLOUD_REQUIRED",
                "Select a folder in iCloud Drive. Sign in to your Apple Account and enable iCloud Drive in Settings first."
            )
        }
    }

    private func finishPickerError(_ code: String, _ message: String) {
        guard let result = pickerResult else { return }
        pickerResult = nil
        pickerController = nil
        result(FlutterError(code: code, message: message, details: nil))
    }

    private func failure(_ code: String, _ message: String) -> NSError {
        NSError(
            domain: "iCloudSavesV2.\(code)",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
