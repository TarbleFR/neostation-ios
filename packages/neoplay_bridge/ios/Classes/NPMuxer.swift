import AVFoundation
import CoreImage
import ReplayKit
import UniformTypeIdentifiers

// v1 fMP4 encoder (Chromecast and MediaSource receivers). Video appends and
// cancel belong to the capture queue; audio appends belong to the capture's
// audio queue, so sound never waits behind a picture. AVAssetWriter accepts
// each input from its own thread; the shared timeline words live under a lock.
final class NPMuxer: NSObject, AVAssetWriterDelegate {
    let source: NPSize
    let output: NPSize
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var origin: CMTime?            // lock
    private var cancelled = false          // lock
    private var lastVideo = CMTime.invalid // capture queue
    private var lastAudio = CMTime.invalid // audio queue
    private var lastAudioEnd = CMTime.invalid // audio queue
    private var pendingAudio: [CMSampleBuffer] = [] // audio queue: buffers the writer was not ready for
    private(set) var audioDeferred = 0  // audio queue
    private(set) var audioSilence = 0   // audio queue: frames of silence inserted into gaps
    private(set) var audioDropped = 0   // audio queue: non-monotonic buffers
    private let interval: Double
    static let maxPendingAudio = 64
    static let silenceGap = 0.08 // seconds without app audio before the track is padded
    static let maxSilence = 2.0  // longest single padding chunk
    static let maxSilenceChunks = 15 // a gap beyond 30 s (a paused game) is closed by one re-anchored buffer
    private var formatRecorded = false // audio queue
    var onSegment: ((Data, Bool, Double) -> Void)?
    var onError: ((NPError) -> Void)?
    private func fail(_ error: NPError) { lock.lock(); let sink = cancelled ? nil : onError; lock.unlock(); sink?(error) }

    convenience init(source: NPSize, display: NPSize, cast: Bool) throws {
        try self.init(source: source, display: display, cast: cast, cap: cast ? NPSize(width: 1280, height: 720) : NPPolicy.legacyCap)
    }
    init(source: NPSize, display: NPSize, cast: Bool, cap: NPSize) throws {
        self.source = source
        output = NPPolicy.encodeSize(source: source, display: display, cap: cast ? NPSize(width: 1280, height: 720) : cap)
        interval = cast ? 1 : 0.25
        writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: interval, preferredTimescale: 600)
        writer.initialSegmentStartTime = .zero
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: output.width, AVVideoHeightKey: output.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: NPPolicy.bitrate(for: output, cast: cast), AVVideoProfileLevelKey: cast ? AVVideoProfileLevelH264BaselineAutoLevel : AVVideoProfileLevelH264HighAutoLevel, AVVideoAllowFrameReorderingKey: false, AVVideoMaxKeyFrameIntervalDurationKey: interval, AVVideoExpectedSourceFrameRateKey: 60]
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000])
        video.expectsMediaDataInRealTime = true; audio.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: output.width, kCVPixelBufferHeightKey as String: output.height, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        super.init()
        guard writer.canAdd(video), writer.canAdd(audio) else { throw NPError.encoder }
        writer.add(video); writer.add(audio); writer.delegate = self
        guard writer.startWriting() else { NPLog.error("encoder.start", writer.error); throw NPError.encoder }
        NPLog.record("encoder.config", ["cast": cast, "width": output.width, "height": output.height, "fragmentSeconds": interval])
        writer.startSession(atSourceTime: .zero)
    }
    static func image(_ sample: CMSampleBuffer) -> CIImage? {
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let orientation = (CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.int32Value ?? 1
        return CIImage(cvPixelBuffer: pixel).oriented(forExifOrientation: orientation)
    }
    private func relative(_ timestamp: CMTime, video isVideo: Bool) -> CMTime? {
        lock.lock(); defer { lock.unlock() }
        if origin == nil { guard isVideo else { return nil }; origin = timestamp }
        guard let origin else { return nil }
        let time = CMTimeSubtract(timestamp, origin)
        return time >= .zero ? time : nil
    }
    func append(_ sample: CMSampleBuffer, video isVideo: Bool) {
        lock.lock(); let live = !cancelled; lock.unlock()
        guard live else { return }
        guard writer.status == .writing else { NPLog.error("encoder.status", writer.error); fail(.encoder); return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard timestamp.isNumeric, let time = relative(timestamp, video: isVideo) else { return }
        if isVideo { appendVideo(sample, time: time) } else { appendAudio(sample, time: time) }
    }
    private func appendVideo(_ sample: CMSampleBuffer, time: CMTime) {
        guard video.isReadyForMoreMediaData, !lastVideo.isNumeric || CMTimeGetSeconds(CMTimeSubtract(time, lastVideo)) >= 1.0/61.0,
              let image = Self.image(sample), let pool = adaptor.pixelBufferPool else { return }
        var pixel: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixel) == kCVReturnSuccess, let pixel else { fail(.encoder); return }
        let bounds = CGRect(x: 0, y: 0, width: output.width, height: output.height)
        let scale = min(bounds.width / image.extent.width, bounds.height / image.extent.height)
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = normalized.transformed(by: CGAffineTransform(translationX: (bounds.width - normalized.extent.width)/2, y: (bounds.height - normalized.extent.height)/2))
        context.render(centered.composited(over: CIImage(color: .black).cropped(to: bounds)), to: pixel, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        if adaptor.append(pixel, withPresentationTime: time) { lastVideo = time } else { NPLog.error("encoder.video", writer.error); fail(.encoder) }
    }
    // Sound: never dropped for a busy writer (deferred, in order), gaps longer
    // than silenceGap padded with silence of the exact length so the AAC
    // timeline stays continuous; only a non-monotonic buffer is refused.
    private func appendAudio(_ sample: CMSampleBuffer, time: CMTime) {
        guard lastAudio.isNumeric == false || time > lastAudio else { audioDropped += 1; if audioDropped % 50 == 1 { NPLog.record("audio.nonmonotonic", ["count": audioDropped]) }; return }
        guard let adjusted = Self.retimed(sample, to: time) else { return }
        if !formatRecorded, let format = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            formatRecorded = true
            NPLog.record("audio.format", ["sampleRate": asbd.mSampleRate, "channels": Int(asbd.mChannelsPerFrame), "interleaved": asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0, "float": asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, "frames": CMSampleBufferGetNumSamples(sample)])
        }
        if lastAudioEnd.isNumeric, CMTimeGetSeconds(CMTimeSubtract(time, lastAudioEnd)) > Self.silenceGap {
            var from = lastAudioEnd, chunks = 0
            while CMTimeGetSeconds(CMTimeSubtract(time, from)) > 0.001, chunks < Self.maxSilenceChunks, let silence = Self.silence(like: sample, from: from, to: time) {
                let frames = CMSampleBufferGetNumSamples(silence); audioSilence += frames; enqueue(silence); chunks += 1
                let duration = CMSampleBufferGetDuration(silence)
                from = CMTimeAdd(from, CMTimeMultiply(duration, multiplier: Int32(frames)))
            }
        }
        enqueue(adjusted)
        lastAudio = time
        let duration = CMSampleBufferGetDuration(sample)
        lastAudioEnd = duration.isNumeric ? CMTimeAdd(time, duration) : time
        flushAudio()
    }
    private func enqueue(_ buffer: CMSampleBuffer) {
        pendingAudio.append(buffer)
        if pendingAudio.count > Self.maxPendingAudio { pendingAudio.removeFirst(); audioDropped += 1 }
    }
    private func flushAudio() {
        while !pendingAudio.isEmpty, audio.isReadyForMoreMediaData {
            let buffer = pendingAudio.removeFirst()
            if !audio.append(buffer) { NPLog.error("encoder.audio", writer.error); fail(.encoder); return }
        }
        if !pendingAudio.isEmpty { audioDeferred += 1 }
    }
    private static func retimed(_ sample: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0, count <= 4096 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil) == noErr else { return nil }
        let shift = CMTimeSubtract(timing[0].presentationTimeStamp, time)
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, shift)
            if timing[index].decodeTimeStamp.isNumeric { timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, shift) }
        }
        var adjusted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &adjusted) == noErr else { return nil }
        return adjusted
    }
    // Zero PCM in the layout of `like`, covering [from, to). Interleaved
    // formats only: a planar buffer is laid out per channel and is not padded.
    static func silence(like sample: CMSampleBuffer, from: CMTime, to: CMTime) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0, asbd.mBytesPerFrame > 0, asbd.mSampleRate > 0 else { return nil }
        let seconds = min(maxSilence, CMTimeGetSeconds(CMTimeSubtract(to, from)))
        let frames = Int(seconds * asbd.mSampleRate)
        guard frames > 0 else { return nil }
        let length = frames * Int(asbd.mBytesPerFrame)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)), presentationTimeStamp: from, decodeTimeStamp: .invalid)
        var size = Int(asbd.mBytesPerFrame), created: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &created) == noErr else { return nil }
        return created
    }
    func finish(_ completion: @escaping () -> Void) {
        guard writer.status == .writing else { completion(); return }
        video.markAsFinished(); audio.markAsFinished(); writer.finishWriting(completionHandler: completion)
    }
    // Called on the capture's audio queue (behind any in-flight sound append);
    // pictures stop earlier because the capture dropped its reference first.
    func cancel() { lock.lock(); cancelled = true; onSegment = nil; onError = nil; lock.unlock(); writer.cancelWriting() }
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        let initial = segmentType == .initialization
        let duration = segmentReport?.trackReports.map { CMTimeGetSeconds($0.duration) }.filter { $0.isFinite && $0 > 0 }.max() ?? interval
        lock.lock(); let sink = cancelled ? nil : onSegment; lock.unlock()
        sink?(data, initial, duration)
    }
}
