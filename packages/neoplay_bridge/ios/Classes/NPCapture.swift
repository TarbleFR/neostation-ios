import Foundation
import ReplayKit
import UIKit

// This class owns only its ReplayKit capture and encoder. No emulator, JIT, VPN or audio-session setters.
// Two encoders: NPFrameEncoder (v2, per-picture packets, Windows receivers that
// advertise `frames`) and NPMuxer (v1 fMP4 segments, cast routes and old receivers).
// Pictures are rendered and submitted on the capture queue; sound has its own
// queue so a 60 fps render backlog never delays or discards an audio buffer.
final class NPCapture: NSObject, RPScreenRecorderDelegate {
    private let queue = DispatchQueue(label: "neoplay.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "neoplay.audio", qos: .userInteractive)
    private let videoSlots = DispatchSemaphore(value: 3)
    private let audioSlots = DispatchSemaphore(value: 64) // ~1.4 s of ReplayKit audio; exceeding it is counted, never silent
    private let outputSlots = DispatchSemaphore(value: 8)
    private let state = NSLock() // generation, encoder, muxer: read from both media queues
    private var generation = 0
    private var activeDisplay = NPSize(width: 1280, height: 720)
    private var displayRevision = 0
    private var muxer: NPMuxer?
    private var encoder: NPFrameEncoder?
    private var requested = false // main-thread state
    private var ownsRecorder = false
    private var pending = false
    private var previousMicrophone = false
    private weak var previousDelegate: RPScreenRecorderDelegate?
    var onSegment: ((Data, Bool, Double) -> Void)?
    var onPacket: ((Data) -> Void)?
    var onError: ((NPError) -> Void)?
    var onStarted: (() -> Void)?
    var onStopped: (() -> Void)?
    var display = NPSize(width: 1280, height: 720)
    var cast = false
    var frames = false // receiver accepts the v2 frame protocol
    var receiverMax = NPPolicy.legacyCap // largest picture the receiver decodes
    private var tier = NPPolicy.Tier.native // capture queue
    private var lastSampleAt = Date()
    private var watchdog: Timer?
    private var audioDropped = 0 // ReplayKit callback thread
    private var videoDropped = 0
    private var cap: NPSize { NPPolicy.cap(tier: cast ? .half : tier, receiverMax: cast ? NPSize(width: 1280, height: 720) : receiverMax) }
    var diagnostics: [String: Any] {
        state.lock(); let encoder = self.encoder, muxer = self.muxer; state.unlock()
        return ["tier": tier.rawValue, "audioDropped": audioDropped, "videoDropped": videoDropped,
                "output": encoder.map { ["width": $0.output.width, "height": $0.output.height] } ?? muxer.map { ["width": $0.output.width, "height": $0.output.height] } ?? NSNull(),
                "passthrough": encoder?.passthrough ?? 0, "audioPackets": encoder?.audioPackets ?? 0, "reanchors": encoder?.reanchors ?? 0]
    }
    func start() {
        let recorder = RPScreenRecorder.shared()
        guard !pending, !ownsRecorder, recorder.isAvailable, !recorder.isRecording else { onError?(.unavailable); return }
        requested = true; pending = true; previousMicrophone = recorder.isMicrophoneEnabled; previousDelegate = recorder.delegate
        recorder.isMicrophoneEnabled = false; recorder.delegate = self
        let display = self.display, cast = self.cast, perFrame = self.frames && !self.cast
        state.lock(); generation += 1; let token = generation; state.unlock()
        queue.sync { activeDisplay = display; lastSampleAt = Date() }
        recorder.startCapture(handler: { [weak self] sample, kind, error in
            guard let self else { return }
            if error != nil { NPLog.error("capture.sample", error); DispatchQueue.main.async { if self.requested { self.onError?(.capture) } }; return }
            guard kind == .video || kind == .audioApp else { return }
            if kind == .audioApp {
                guard self.audioSlots.wait(timeout: .now()) == .success else { self.audioDropped += 1; if self.audioDropped % 100 == 1 { NPLog.record("audio.dropped", ["count": self.audioDropped]) }; return }
                self.audioQueue.async {
                    defer { self.audioSlots.signal() }
                    self.state.lock(); let live = token == self.generation, encoder = self.encoder, muxer = self.muxer; self.state.unlock()
                    guard live else { return }
                    if perFrame { encoder?.append(sample, video: false) } else { muxer?.append(sample, video: false) }
                }
                return
            }
            guard self.videoSlots.wait(timeout: .now()) == .success else { self.videoDropped += 1; return }
            self.queue.async {
                defer { self.videoSlots.signal() }
                self.state.lock(); let live = token == self.generation; self.state.unlock()
                guard live else { return }; self.lastSampleAt = Date()
                do {
                    guard let image = NPMuxer.image(sample) else { return }
                    let size = NPSize(width: Int(image.extent.width), height: Int(image.extent.height))
                    if perFrame {
                        if self.encoder?.source != size {
                            self.encoder?.cancel()
                            let encoder = try NPFrameEncoder(source: size, display: self.activeDisplay, cap: self.cap)
                            self.state.lock(); self.encoder = encoder; self.state.unlock()
                            encoder.onError = { [weak self] error in DispatchQueue.main.async { if self?.requested == true { self?.onError?(error) } } }
                            // VideoToolbox calls back on its own thread and sound arrives from the
                            // audio queue; both hop to the capture queue so packets leave in order
                            // per stream and the transport sees one producer.
                            encoder.onPacket = { [weak self, weak encoder] packet in
                                guard let self else { return }
                                guard self.outputSlots.wait(timeout: .now()) == .success else { DispatchQueue.main.async { self.onError?(.backpressure) }; return }
                                self.queue.async {
                                    defer { self.outputSlots.signal() }
                                    self.state.lock(); let live = token == self.generation && self.encoder === encoder; self.state.unlock()
                                    guard live else { return }
                                    self.onPacket?(packet)
                                }
                            }
                        }
                        self.encoder?.append(sample, video: true)
                    } else {
                        if self.muxer?.source != size {
                            self.muxer?.cancel()
                            let muxer = try NPMuxer(source: size, display: self.activeDisplay, cast: cast, cap: self.cap)
                            self.state.lock(); self.muxer = muxer; self.state.unlock()
                            muxer.onError = { [weak self] error in DispatchQueue.main.async { if self?.requested == true { self?.onError?(error) } } }
                            muxer.onSegment = { [weak self, weak muxer] bytes, initial, duration in
                                guard let self else { return }
                                guard self.outputSlots.wait(timeout: .now()) == .success else { DispatchQueue.main.async { self.onError?(.backpressure) }; return }
                                self.queue.async {
                                    defer { self.outputSlots.signal() }
                                    self.state.lock(); let live = token == self.generation && self.muxer === muxer; self.state.unlock()
                                    guard live else { return }
                                    self.onSegment?(bytes, initial, duration)
                                }
                            }
                        }
                        self.muxer?.append(sample, video: true)
                    }
                } catch { DispatchQueue.main.async { if self.requested { self.onError?(.encoder) } } }
            }
        }, completionHandler: { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }; self.pending = false
                if error != nil { NPLog.error("capture.start", error); let notify = self.requested; self.requested = false; self.restoreRecorder(); if notify { self.onError?(.capture) }; self.onStopped?(); return }
                self.ownsRecorder = true
                guard self.requested else { self.stop(); return }
                self.onStarted?()
                self.watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { let stalled = Date().timeIntervalSince(self.lastSampleAt) > 12; DispatchQueue.main.async { if stalled && self.requested { self.onError?(.timeout) } } }
                }
            }
        })
    }
    func updateDisplay(_ size: NPSize) {
        queue.async {
            self.displayRevision += 1
            let revision = self.displayRevision
            self.state.lock(); let token = self.generation; self.state.unlock()
            self.queue.asyncAfter(deadline: .now() + 0.5) {
                self.state.lock(); let live = self.generation == token; self.state.unlock()
                guard live, self.displayRevision == revision else { return }
                self.activeDisplay = size
                self.restartEncodersIfOutputChanges(reason: "display.resize", detail: ["width": size.width, "height": size.height])
            }
        }
    }
    // Link adaptation: a lower tier lowers the ceiling; the next picture
    // recreates the encoder. The game never restarts.
    func setTier(_ tier: NPPolicy.Tier) {
        queue.async {
            guard tier != self.tier else { return }
            self.tier = tier
            self.restartEncodersIfOutputChanges(reason: "link.tier", detail: ["tier": tier.rawValue])
        }
    }
    // A shed picture: the receiver resumes at the next key picture.
    func linkShed() { state.lock(); let encoder = self.encoder; state.unlock(); encoder?.requestKeyFrame() }
    private func restartEncodersIfOutputChanges(reason: String, detail: [String: Any]) {
        if let encoder = self.encoder, NPPolicy.encodeSize(source: encoder.source, display: activeDisplay, cap: cap) != encoder.output {
            NPLog.record(reason, detail); encoder.cancel(); state.lock(); self.encoder = nil; state.unlock()
        }
        guard let muxer = self.muxer, NPPolicy.encodeSize(source: muxer.source, display: activeDisplay, cap: cap) != muxer.output else { return }
        NPLog.record(reason, detail)
        muxer.cancel(); state.lock(); self.muxer = nil; state.unlock()
    }
    func stop() {
        requested = false; watchdog?.invalidate(); watchdog = nil
        state.lock(); generation += 1; state.unlock()
        queue.async { self.muxer?.cancel(); self.encoder?.cancel(); self.state.lock(); self.muxer = nil; self.encoder = nil; self.state.unlock() }
        if pending { return } // The late start completion stops its own recorder before another session can start.
        guard ownsRecorder else { onStopped?(); return }; ownsRecorder = false
        RPScreenRecorder.shared().stopCapture { [weak self] _ in DispatchQueue.main.async { self?.restoreRecorder(); self?.onStopped?() } }
    }
    private func restoreRecorder() { let recorder = RPScreenRecorder.shared(); if recorder.delegate === self { recorder.delegate = previousDelegate; previousDelegate = nil; recorder.isMicrophoneEnabled = previousMicrophone } }
    func screenRecorder(_ screenRecorder: RPScreenRecorder, didStopRecordingWith previewViewController: RPPreviewViewController?, error: Error?) { if requested { onError?(.capture) } }
}
