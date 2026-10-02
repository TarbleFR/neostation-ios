import AVFoundation
import CoreImage
import ReplayKit
import UniformTypeIdentifiers

// All append/cancel calls belong to the capture queue. Delegate output is fenced by its owner.
final class NPMuxer: NSObject, AVAssetWriterDelegate {
    let source: NPSize
    let output: NPSize
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var origin: CMTime?
    private var lastVideo = CMTime.invalid
    private var lastAudio = CMTime.invalid
    private let interval: Double
    var onSegment: ((Data, Bool, Double) -> Void)?
    var onError: ((NPError) -> Void)?

    init(source: NPSize, display: NPSize, cast: Bool) throws {
        self.source = source
        output = NPPolicy.encodeSize(source: source, display: display, cap: cast ? NPSize(width: 1280, height: 720) : NPSize(width: 1920, height: 1080))
        interval = cast ? 1 : 0.25
        writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: interval, preferredTimescale: 600)
        writer.initialSegmentStartTime = .zero
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: output.width, AVVideoHeightKey: output.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(12000000, max(2000000, output.width * output.height * 6)), AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel, AVVideoAllowFrameReorderingKey: false, AVVideoMaxKeyFrameIntervalDurationKey: interval, AVVideoExpectedSourceFrameRateKey: 60]
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000])
        video.expectsMediaDataInRealTime = true; audio.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: output.width, kCVPixelBufferHeightKey as String: output.height, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        super.init()
        guard writer.canAdd(video), writer.canAdd(audio) else { throw NPError.encoder }
        writer.add(video); writer.add(audio); writer.delegate = self
        guard writer.startWriting() else { throw NPError.encoder }
        writer.startSession(atSourceTime: .zero)
    }
    static func image(_ sample: CMSampleBuffer) -> CIImage? {
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let orientation = (CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.int32Value ?? 1
        return CIImage(cvPixelBuffer: pixel).oriented(forExifOrientation: orientation)
    }
    func append(_ sample: CMSampleBuffer, video isVideo: Bool) {
        guard writer.status == .writing else { onError?(.encoder); return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard timestamp.isNumeric else { return }
        if origin == nil { guard isVideo else { return }; origin = timestamp }
        guard let origin else { return }
        let time = CMTimeSubtract(timestamp, origin)
        guard time >= .zero else { return }
        if isVideo {
            guard video.isReadyForMoreMediaData, !lastVideo.isNumeric || CMTimeGetSeconds(CMTimeSubtract(time, lastVideo)) >= 1.0/61.0,
                  let image = Self.image(sample), let pool = adaptor.pixelBufferPool else { return }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixel) == kCVReturnSuccess, let pixel else { onError?(.encoder); return }
            let bounds = CGRect(x: 0, y: 0, width: output.width, height: output.height)
            let scale = min(bounds.width / image.extent.width, bounds.height / image.extent.height)
            let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let centered = normalized.transformed(by: CGAffineTransform(translationX: (bounds.width - normalized.extent.width)/2, y: (bounds.height - normalized.extent.height)/2))
            context.render(centered.composited(over: CIImage(color: .black).cropped(to: bounds)), to: pixel, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            if adaptor.append(pixel, withPresentationTime: time) { lastVideo = time } else { onError?(.encoder) }
        } else {
            guard audio.isReadyForMoreMediaData, !lastAudio.isNumeric || time > lastAudio else { return }
            var count = 0
            guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0, count <= 4096 else { return }
            var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
            guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil) == noErr else { return }
            for index in timing.indices {
                timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, origin)
                if timing[index].decodeTimeStamp.isNumeric { timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, origin) }
            }
            var adjusted: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &adjusted) == noErr, let adjusted else { return }
            if audio.append(adjusted) { lastAudio = time } else { onError?(.encoder) }
        }
    }
    func finish(_ completion: @escaping () -> Void) {
        guard writer.status == .writing else { completion(); return }
        video.markAsFinished(); audio.markAsFinished(); writer.finishWriting(completionHandler: completion)
    }
    func cancel() { onSegment = nil; onError = nil; writer.cancelWriting() }
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        let initial = segmentType == .initialization
        let duration = segmentReport?.trackReports.map { CMTimeGetSeconds($0.duration) }.filter { $0.isFinite && $0 > 0 }.max() ?? interval
        onSegment?(data, initial, duration)
    }
}
