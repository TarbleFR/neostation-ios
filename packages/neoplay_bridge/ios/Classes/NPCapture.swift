import Foundation
import ReplayKit
import UIKit

// This class owns only its ReplayKit capture and encoder. No emulator, JIT, VPN or audio-session setters.
// Two encoders: NPFrameEncoder (v2, per-picture packets, Windows receivers that
// advertise `frames`) and NPMuxer (v1 fMP4 segments, cast routes and old receivers).
final class NPCapture: NSObject, RPScreenRecorderDelegate {
    private let queue = DispatchQueue(label: "neoplay.capture", qos: .userInteractive)
    private let videoSlots = DispatchSemaphore(value: 3)
    private let audioSlots = DispatchSemaphore(value: 16)
    private let outputSlots = DispatchSemaphore(value: 8)
    private var generation = 0 // queue-confined
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
    private var lastSampleAt = Date()
    private var watchdog: Timer?
    func start() {
        let recorder = RPScreenRecorder.shared()
        guard !pending, !ownsRecorder, recorder.isAvailable, !recorder.isRecording else { onError?(.unavailable); return }
        requested = true; pending = true; previousMicrophone = recorder.isMicrophoneEnabled; previousDelegate = recorder.delegate
        recorder.isMicrophoneEnabled = false; recorder.delegate = self
        let display = self.display, cast = self.cast, perFrame = self.frames && !self.cast
        queue.sync { generation += 1; activeDisplay = display; lastSampleAt = Date() }
        let token = queue.sync { generation }
        recorder.startCapture(handler: { [weak self] sample, kind, error in
            guard let self else { return }
            if error != nil { NPLog.error("capture.sample", error); DispatchQueue.main.async { if self.requested { self.onError?(.capture) } }; return }
            guard kind == .video || kind == .audioApp else { return }
            let slots = kind == .video ? self.videoSlots : self.audioSlots
            guard slots.wait(timeout: .now()) == .success else { return }
            self.queue.async {
                defer { slots.signal() }
                guard token == self.generation else { return }; self.lastSampleAt = Date()
                do {
                    if kind == .video, let image = NPMuxer.image(sample) {
                        let size = NPSize(width: Int(image.extent.width), height: Int(image.extent.height))
                        if perFrame {
                            if self.encoder?.source != size {
                                self.encoder?.cancel()
                                let encoder = try NPFrameEncoder(source: size, display: self.activeDisplay); self.encoder = encoder
                                encoder.onError = { [weak self] error in DispatchQueue.main.async { if self?.requested == true { self?.onError?(error) } } }
                                // VideoToolbox calls back on its own thread; the packet order is preserved by hopping to the capture queue.
                                encoder.onPacket = { [weak self, weak encoder] packet in
                                    guard let self else { return }
                                    guard self.outputSlots.wait(timeout: .now()) == .success else { DispatchQueue.main.async { self.onError?(.backpressure) }; return }
                                    self.queue.async {
                                        defer { self.outputSlots.signal() }
                                        guard token == self.generation, self.encoder === encoder else { return }
                                        self.onPacket?(packet)
                                    }
                                }
                            }
                        } else if self.muxer?.source != size {
                            self.muxer?.cancel()
                            let muxer = try NPMuxer(source: size, display: self.activeDisplay, cast: cast); self.muxer = muxer
                            muxer.onError = { [weak self] error in DispatchQueue.main.async { if self?.requested == true { self?.onError?(error) } } }
                            muxer.onSegment = { [weak self, weak muxer] bytes, initial, duration in
                                guard let self else { return }
                                guard self.outputSlots.wait(timeout: .now()) == .success else { DispatchQueue.main.async { self.onError?(.backpressure) }; return }
                                self.queue.async {
                                    defer { self.outputSlots.signal() }
                                    guard token == self.generation, self.muxer === muxer else { return }
                                    self.onSegment?(bytes, initial, duration)
                                }
                            }
                        }
                    }
                    if perFrame { self.encoder?.append(sample, video: kind == .video) } else { self.muxer?.append(sample, video: kind == .video) }
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
            let revision = self.displayRevision, token = self.generation
            self.queue.asyncAfter(deadline: .now() + 0.5) {
                guard self.generation == token, self.displayRevision == revision else { return }
                self.activeDisplay = size
                // Only restart the encoder after a settled viewport change, never the game.
                if let encoder = self.encoder, NPPolicy.encodeSize(source: encoder.source, display: size) != encoder.output {
                    NPLog.record("display.resize", ["width": size.width, "height": size.height]); encoder.cancel(); self.encoder = nil
                }
                guard let muxer = self.muxer, NPPolicy.encodeSize(source: muxer.source, display: size) != muxer.output else { return }
                NPLog.record("display.resize", ["width": size.width, "height": size.height])
                muxer.cancel(); self.muxer = nil
            }
        }
    }
    func stop() {
        requested = false; watchdog?.invalidate(); watchdog = nil
        queue.async { self.generation += 1; self.muxer?.cancel(); self.muxer = nil; self.encoder?.cancel(); self.encoder = nil }
        if pending { return } // The late start completion stops its own recorder before another session can start.
        guard ownsRecorder else { onStopped?(); return }; ownsRecorder = false
        RPScreenRecorder.shared().stopCapture { [weak self] _ in DispatchQueue.main.async { self?.restoreRecorder(); self?.onStopped?() } }
    }
    private func restoreRecorder() { let recorder = RPScreenRecorder.shared(); if recorder.delegate === self { recorder.delegate = previousDelegate; previousDelegate = nil; recorder.isMicrophoneEnabled = previousMicrophone } }
    func screenRecorder(_ screenRecorder: RPScreenRecorder, didStopRecordingWith previewViewController: RPPreviewViewController?, error: Error?) { if requested { onError?(.capture) } }
}
