import Foundation
import UIKit
import AVFoundation
import MediaPlayer

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
    private let localOutput = NPSystemVolumeOutput()
    private lazy var localAudio = NPLocalAudioLease(output: localOutput)
    private var audioWatchdog: Timer?
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
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in if self?.localAudio.active == true { self?.stop() } }
    }
    var snapshot: [String: Any] { ["state": state, "error": failure as Any? ?? NSNull(), "localAudioSuppressed": localAudio.active, "selected": selected as Any? ?? NSNull(), "receivers": discovery.receivers + cast.receivers, "appleTV": airplay.snapshot, "stream": capture?.diagnostics ?? NSNull(), "physicalValidation": ["windows": false, "chromecast": false, "appleTV": false, "controllerBattery": false]] }
    private func publish() { changed?(snapshot) }
    func discover() { failure = nil; discovery.start(); cast.startDiscovery(); publish() }
    func stopDiscovery() { discovery.stop(); cast.stopDiscovery() }
    func connect(id: String, pin: String, stopLabel: String) throws {
        guard !NPAirPlayMonitor.facts().externalMirroring, !isStopping, !localAudio.active, let token = fence.begin() else { throw NPError.busy }
        NPLog.record("session.connect", ["kind": id.hasPrefix("cast:") ? "cast" : "windows"])
        state = "connecting"; failure = nil; selected = id; didLoadCast = false; publish()
        let fail: (NPError) -> Void = { [weak self] error in DispatchQueue.main.async { guard let self, self.fence.accepts(token) else { return }; self.stop(error: error) } }
        let playing: () -> Void = { [weak self] in DispatchQueue.main.async {
            guard let self, self.fence.accepts(token) else { return }
            if id.hasPrefix("windows:"), !self.localAudio.active {
                self.showOverlay(label: stopLabel)
                guard self.localAudio.begin() else { self.stop(error: .unavailable); return }
                let audioToken = self.localAudio.generation
                var unconfirmed = 0
                self.audioWatchdog?.invalidate()
                self.audioWatchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
                    guard let self, self.fence.accepts(token), self.localAudio.active else { timer.invalidate(); return }
                    if self.localAudio.verify(audioToken) { unconfirmed = 0 }
                    else {
                        unconfirmed += 1
                        if unconfirmed >= 4 || !self.localAudio.enforce(audioToken) { self.stop(error: .unavailable) }
                    }
                }
                NPLog.record("audio.local.suppressed")
            }
            self.state = "streaming"; NPLog.record("receiver.playing"); self.startTimer?.invalidate(); self.startTimer = nil; self.publish()
        } }
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
        audioWatchdog?.invalidate(); audioWatchdog = nil
        let restored = localAudio.end()
        NPLog.record("audio.local.restore.requested", ["accepted": restored])
        failure = error?.rawValue; state = error == nil ? "idle" : "failed"; selected = nil
        windows?.stop(); windows = nil; cast.stop(); http?.stop(); http = nil; store = nil; mediaURL = nil
        if restored { overlay?.isHidden = true; overlay = nil }
        else {
            var attempts = 0
            audioWatchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                attempts += 1
                if self.localAudio.end() {
                    timer.invalidate(); self.audioWatchdog = nil
                    self.overlay?.isHidden = true; self.overlay = nil
                    self.publish()
                } else if attempts >= 20 {
                    timer.invalidate(); self.audioWatchdog = nil
                    NPLog.record("audio.local.restore.failed")
                    self.publish()
                }
            }
        }
        isStopping = capture != nil; capture?.stop(); publish()
    }
    private func showOverlay(label: String) {
        guard overlay == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        let window = NPOverlayWindow(windowScene: scene); window.windowLevel = .alert - 1
        let controller = UIViewController(); controller.view.backgroundColor = .clear; window.rootViewController = controller
        controller.view.addSubview(localOutput.view)
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


protocol NPVolumeOutput: AnyObject {
    var volume: Float { get }
    func setVolume(_ value: Float) -> Bool
}

final class NPLocalAudioLease {
    private let output: NPVolumeOutput
    private var original: Float?
    private var attenuationRequested = false
    private(set) var generation = 0
    var active: Bool { original != nil }
    init(output: NPVolumeOutput) { self.output = output }
    @discardableResult func begin() -> Bool {
        if active { return true }
        let value = output.volume
        guard value.isFinite, (0...1).contains(value) else { return false }
        original = value; generation += 1
        if value <= 0.001 { return true }
        guard output.setVolume(0) else { _ = end(); return false }
        attenuationRequested = true
        return true
    }
    func verify(_ token: Int) -> Bool { active && token == generation && output.volume <= 0.001 }
    func enforce(_ token: Int) -> Bool {
        guard active, token == generation else { return false }
        return output.volume <= 0.001 || output.setVolume(0)
    }
    @discardableResult func end() -> Bool {
        guard let value = original else { return true }
        generation += 1
        if attenuationRequested || abs(output.volume - value) > 0.02 {
            guard output.setVolume(value) else { return false }
        }
        guard abs(output.volume - value) <= 0.02 else { return false }
        original = nil; attenuationRequested = false
        return true
    }
}

final class NPSystemVolumeOutput: NPVolumeOutput {
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 120, height: 24))
    var volume: Float { AVAudioSession.sharedInstance().outputVolume }
    init() {
        view.showsRouteButton = false
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
    }
    func setVolume(_ value: Float) -> Bool {
        guard view.window != nil, let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return false }
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
        return true
    }
}
