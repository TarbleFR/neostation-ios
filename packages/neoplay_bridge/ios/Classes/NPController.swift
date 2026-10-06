import Foundation
import UIKit

final class NPController {
    let discovery = NPDiscovery()
    let cast = NPGoogleCast()
    let airplay = NPAirPlayMonitor()
    private var fence = NPSessionFence()
    private var capture: NPCapture?
    private var windows: NPWindowsTransport?
    private var http: NPHTTPServer?
    private var store: NPSegmentStore?
    private var overlay: UIWindow?
    private(set) var state = "idle"
    private var failure: String?
    private var selected: String?
    private var isStopping = false
    private var startTimer: Timer?
    private var didLoadCast = false
    private var mediaURL: URL?
    private var adapter = NPLinkAdapter()
    private var adapterTimer: Timer?
    var changed: (([String: Any]) -> Void)?
    init() {
        discovery.changed = { [weak self] in self?.publish() }; cast.changed = { [weak self] in self?.publish() }
        airplay.changed = { [weak self] in
            guard let self else { return }
            if NPAirPlayMonitor.facts().externalMirroring && self.fence.active { self.stop(error:.busy) } else { self.publish() }
        }
        airplay.start()
        discovery.failed = { [weak self] in self?.failure = NPError.network.rawValue; self?.publish() }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in if self?.fence.active == true { self?.stop() } }
    }
    var snapshot: [String: Any] { ["state": state, "error": failure as Any? ?? NSNull(), "selected": selected as Any? ?? NSNull(), "receivers": discovery.receivers + cast.receivers, "appleTV": airplay.snapshot, "stream": capture?.diagnostics ?? NSNull(), "physicalValidation": ["windows": false, "chromecast": false, "appleTV": false, "controllerBattery": false]] }
    private func publish() { changed?(snapshot) }
    func discover() { failure = nil; discovery.start(); cast.startDiscovery(); publish() }
    func stopDiscovery() { discovery.stop(); cast.stopDiscovery() }
    func connect(id: String, pin: String, stopLabel: String) throws {
        guard !NPAirPlayMonitor.facts().externalMirroring, !isStopping, let token = fence.begin() else { throw NPError.busy }
        NPLog.record("session.connect", ["kind": id.hasPrefix("cast:") ? "cast" : "windows"])
        state = "connecting"; failure = nil; selected = id; didLoadCast = false; publish()
        let fail: (NPError) -> Void = { [weak self] error in DispatchQueue.main.async { guard let self, self.fence.accepts(token) else { return }; self.stop(error: error) } }
        let playing: () -> Void = { [weak self] in DispatchQueue.main.async { guard let self, self.fence.accepts(token) else { return }; self.state = "streaming"; NPLog.record("receiver.playing"); self.startTimer?.invalidate(); self.startTimer = nil; self.publish() } }
        startTimer = Timer.scheduledTimer(withTimeInterval: 40, repeats: false) { _ in fail(.timeout) }
        if id.hasPrefix("windows:"), let service = discovery.services[id], let host = service.hostName {
            let transport = NPWindowsTransport(); windows = transport; transport.onError = fail; transport.onPlayback = playing
            transport.onReady = { [weak self, weak transport] size in DispatchQueue.main.async { self?.startCapture(token: token, size: size, castRoute: false, stopLabel: stopLabel, frames: transport?.framesSupported == true, receiverMax: transport?.receiverMax ?? NPPolicy.legacyCap) } }
            // A shed picture, or a receiver that cannot decode fast enough, asks for a key picture at once; repeated ones lower the tier.
            let congested: (Int) -> Void = { [weak self] count in DispatchQueue.main.async { guard let self, self.fence.accepts(token) else { return }; self.capture?.linkShed(); if let tier = self.adapter.shed(at: Date().timeIntervalSinceReferenceDate, count: count) { NPLog.record("link.tier", ["tier": tier.rawValue, "dropped": count]); self.capture?.setTier(tier) } } }
            transport.onShed = { count, kind in if kind == 4 { congested(count) } }
            transport.onKeyRequest = { NPLog.record("receiver.keyframe"); congested(1) }
            transport.onDisplay = { [weak self] size in DispatchQueue.main.async { guard let self, self.fence.accepts(token) else { return }; self.capture?.updateDisplay(size) } }
            transport.connect(host: host, port: service.port, pin: pin)
        } else if id.hasPrefix("cast:") {
            let store = NPSegmentStore(); self.store = store; let http = NPHTTPServer(store: store); self.http = http
            cast.onError = fail; cast.onPlayback = playing
            cast.onReady = { [weak self] in
                http.start { result in DispatchQueue.main.async {
                    guard let self, self.fence.accepts(token) else { http.stop(); return }
                    switch result {
                    case .success(let url): self.mediaURL = url; self.startCapture(token: token, size: NPSize(width: 1280, height: 720), castRoute: true, stopLabel: stopLabel)
                    case .failure(let error): fail(error)
                    }
                } }
            }
            cast.connect(id)
        } else { stop(error: .receiverGone); throw NPError.receiverGone }
    }
    private func startCapture(token: Int, size: NPSize, castRoute: Bool, stopLabel: String, frames: Bool = false, receiverMax: NPSize = NPPolicy.legacyCap) {
        guard fence.accepts(token), capture == nil else { return }
        NPLog.record("session.protocol", ["frames": frames, "maxWidth": receiverMax.width, "maxHeight": receiverMax.height])
        let capture = NPCapture(); self.capture = capture; capture.display = size; capture.cast = castRoute; capture.frames = frames; capture.receiverMax = receiverMax
        adapter = NPLinkAdapter(); adapterTimer?.invalidate()
        adapterTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.fence.accepts(token) else { return }
            if let tier = self.adapter.tick(at: Date().timeIntervalSinceReferenceDate) { NPLog.record("link.tier", ["tier": tier.rawValue]); self.capture?.setTier(tier) }
        }
        capture.onError = { [weak self] error in DispatchQueue.main.async { guard let self, self.fence.accepts(token) else { return }; self.stop(error: error) } }
        capture.onStarted = { [weak self] in guard let self, self.fence.accepts(token) else { return }; self.state = "capturing"; self.showOverlay(label: stopLabel); self.publish() }
        let store = self.store, windows = self.windows
        capture.onPacket = { packet in windows?.sendPacket(packet) }
        capture.onSegment = { [weak self] data, initial, duration in
            do {
                if let store { if initial { try store.initialize(data) } else { try store.append(data, duration: duration) } }
                windows?.send(data, initial: initial)
                if castRoute && store?.isReady == true {
                    DispatchQueue.main.async { guard let self, self.fence.accepts(token), !self.didLoadCast, let url = self.mediaURL else { return }; self.didLoadCast = true; self.cast.load(url) }
                }
            } catch { DispatchQueue.main.async { if self?.fence.accepts(token) == true { self?.stop(error: .encoder) } } }
        }
        capture.onStopped = { [weak self, weak capture] in guard let self, self.capture === capture else { return }; self.capture = nil; self.isStopping = false; self.publish() }
        capture.start()
    }
    func stop(error: NPError? = nil) {
        NPLog.record("session.stop", ["reason": error?.rawValue ?? "user"])
        fence.stop(); startTimer?.invalidate(); startTimer = nil; adapterTimer?.invalidate(); adapterTimer = nil
        failure = error?.rawValue; state = error == nil ? "idle" : "failed"; selected = nil
        windows?.stop(); windows = nil; cast.stop(); http?.stop(); http = nil; store = nil; mediaURL = nil
        overlay?.isHidden = true; overlay = nil
        isStopping = capture != nil; capture?.stop(); publish()
    }
    private func showOverlay(label: String) {
        guard overlay == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        let window = NPOverlayWindow(windowScene: scene); window.windowLevel = .alert - 1
        let controller = UIViewController(); controller.view.backgroundColor = .clear; window.rootViewController = controller
        let button = UIButton(type: .system); button.setTitle("NeoPlay ×", for: .normal); button.accessibilityLabel = label; button.accessibilityIdentifier = "neoplay-stop-stream"
        button.backgroundColor = UIColor.black.withAlphaComponent(0.7); button.tintColor = .white; button.layer.cornerRadius = 12
        button.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(button)
        NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.centerXAnchor), button.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 8), button.widthAnchor.constraint(equalToConstant: 110), button.heightAnchor.constraint(equalToConstant: 36)])
        button.addAction(UIAction { [weak self] _ in self?.stop() }, for: .touchUpInside)
        window.button = button; window.isHidden = false; overlay = window // Never make this the key window.
    }
}
private final class NPOverlayWindow: UIWindow {
    weak var button: UIButton?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let button, button.bounds.contains(convert(point, to: button)) else { return nil }
        return super.hitTest(point, with: event)
    }
}
