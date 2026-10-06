import AVFoundation
import CoreImage
import ReplayKit
import VideoToolbox

// NeoPlay v2 "frame" encoder for Windows receivers (gaming). One packet per
// access unit straight out of VideoToolbox, raw PCM audio, no container and no
// segmenter: nothing waits for a segment boundary. Used instead of NPMuxer when
// the receiver advertises `frames: true`. Cast routes keep NPMuxer (HLS needs segments).
// Wire format (big-endian, first byte = kind):
//  3 config : u16 width, u16 height, u32 audio sample rate, u8 channels, avcC
//  4 video  : u64 pts µs, u8 flags (bit0 key), AVCC access unit (4-byte NAL lengths)
//  5 audio  : u64 pts µs, interleaved s16le PCM
// All append/cancel calls belong to the capture queue; VideoToolbox output is fenced by `cancelled`.
final class NPFrameEncoder {
    let source: NPSize
    let output: NPSize
    private var session: VTCompressionSession?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var origin: CMTime?
    private var lastVideo = CMTime.invalid
    private var configuration: Data?
    private var needKey = true
    private var cancelled = false
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)!
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var audioClock: (origin: Int64, frames: Int64)?
    var onPacket: ((Data) -> Void)?
    var onError: ((NPError) -> Void)?

    init(source: NPSize, display: NPSize) throws {
        self.source = source
        output = NPPolicy.encodeSize(source: source, display: display)
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(output.width), height: Int32(output.height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else { NPLog.record("frames.create", ["status": Int(status)]); throw NPError.encoder }
        self.session = session
        let bitrate = min(12_000_000, max(2_000_000, output.width * output.height * 6))
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_H264EntropyMode: kVTH264EntropyMode_CABAC,
            kVTCompressionPropertyKey_AllowFrameReordering: false,          // no B-frames: decode order == display order
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,                // emit each picture as soon as it is encoded
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 120,             // long GOP: bits go to detail, not to IDRs
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [bitrate / 8, 1] as [NSNumber],
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_AllowTemporalCompression: true,
        ]
        for (key, value) in properties {
            let set = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if set != noErr { NPLog.record("frames.property", ["key": key as String, "status": Int(set)]) } // tolerated: encoder-specific keys
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: output.width,
                                           kCVPixelBufferHeightKey: output.height, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else { throw NPError.encoder }
        self.pool = pool
        NPLog.record("encoder.config", ["cast": false, "width": output.width, "height": output.height, "protocol": 2, "bitrate": bitrate])
    }

    func append(_ sample: CMSampleBuffer, video isVideo: Bool) {
        guard !cancelled else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard timestamp.isNumeric else { return }
        if origin == nil { guard isVideo else { return }; origin = timestamp }
        guard let origin else { return }
        let time = CMTimeSubtract(timestamp, origin)
        guard time >= .zero else { return }
        if isVideo { appendVideo(sample, time: time) } else { appendAudio(sample, time: time) }
    }

    private func appendVideo(_ sample: CMSampleBuffer, time: CMTime) {
        guard let session, let pool, !lastVideo.isNumeric || CMTimeGetSeconds(CMTimeSubtract(time, lastVideo)) >= 1.0 / 61.0,
              let image = NPMuxer.image(sample) else { return }
        var pixel: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixel) == kCVReturnSuccess, let pixel else { onError?(.encoder); return }
        let bounds = CGRect(x: 0, y: 0, width: output.width, height: output.height)
        let scale = min(bounds.width / image.extent.width, bounds.height / image.extent.height)
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = normalized.transformed(by: CGAffineTransform(translationX: (bounds.width - normalized.extent.width) / 2, y: (bounds.height - normalized.extent.height) / 2))
        context.render(centered.composited(over: CIImage(color: .black).cropped(to: bounds)), to: pixel, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        lastVideo = time
        let properties: [CFString: Any]? = needKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] : nil
        needKey = false
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: time, duration: .invalid, frameProperties: properties as CFDictionary?, infoFlagsOut: nil) { [weak self] status, _, encoded in
            guard let self, !self.cancelled else { return }
            guard status == noErr, let encoded, CMSampleBufferDataIsReady(encoded) else { NPLog.record("frames.encode", ["status": Int(status)]); self.onError?(.encoder); return }
            self.emit(encoded)
        }
        if status != noErr { NPLog.record("frames.submit", ["status": Int(status)]); onError?(.encoder) }
    }

    // VideoToolbox output: a sync picture carries SPS/PPS in its format description.
    private func emit(_ encoded: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(encoded, createIfNecessary: false) as? [[CFString: Any]]
        let key = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        if key, let format = CMSampleBufferGetFormatDescription(encoded), let avcC = Self.avcC(format), avcC != configuration {
            configuration = avcC
            var packet = Data([3])
            packet.append(contentsOf: Self.bigEndian(UInt16(output.width))); packet.append(contentsOf: Self.bigEndian(UInt16(output.height)))
            packet.append(contentsOf: Self.bigEndian(UInt32(48000))); packet.append(2); packet.append(avcC)
            onPacket?(packet)
        }
        guard configuration != nil, let block = CMSampleBufferGetDataBuffer(encoded) else { return }
        var length = 0, pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer, length > 0 else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(encoded)
        var packet = Data(capacity: 10 + length); packet.append(4)
        packet.append(contentsOf: Self.bigEndian(UInt64(max(0, Int64(CMTimeGetSeconds(pts) * 1_000_000)))))
        packet.append(key ? 1 : 0); packet.append(UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: length))
        onPacket?(packet)
    }

    private static func avcC(_ format: CMFormatDescription) -> Data? {
        var count = 0, nalLength: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength) == noErr, count >= 2, nalLength == 4 else { return nil }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?, size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer, size > 0 else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        let sps = sets.filter { $0[0] & 0x1f == 7 }, pps = sets.filter { $0[0] & 0x1f == 8 }
        guard let first = sps.first, first.count >= 4, !pps.isEmpty, sps.count < 32, pps.count < 256 else { return nil }
        var avcC = Data([1, first[1], first[2], first[3], 0xff, UInt8(0xe0 | sps.count)])
        for set in sps { avcC.append(contentsOf: bigEndian(UInt16(set.count))); avcC.append(set) }
        avcC.append(UInt8(pps.count))
        for set in pps { avcC.append(contentsOf: bigEndian(UInt16(set.count))); avcC.append(set) }
        return avcC
    }

    // ReplayKit app audio (any PCM layout) -> 48 kHz stereo s16 interleaved.
    private func appendAudio(_ sample: CMSampleBuffer, time: CMTime) {
        guard let format = CMSampleBufferGetFormatDescription(sample), configuration != nil else { return }
        let input = AVAudioFormat(cmAudioFormatDescription: format)
        if converter == nil || converterInput != input {
            guard let created = AVAudioConverter(from: input, to: pcmFormat) else { return }
            converter = created; converterInput = input; audioClock = nil
        }
        guard let converter else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(frames)) else { return }
        source.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: source.mutableAudioBufferList) == noErr else { return }
        let capacity = AVAudioFrameCount(Double(frames) * 48000 / input.sampleRate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true; outStatus.pointee = .haveData; return source
        }
        guard status != .error, converted.frameLength > 0, let bytes = converted.int16ChannelData?.pointee else { return }
        let micro = Int64(CMTimeGetSeconds(time) * 1_000_000)
        // Resampling changes frame counts: time stamps come from a frame counter anchored on the capture clock, re-anchored on a > 50 ms gap.
        if let clock = audioClock, abs(micro - (clock.origin + clock.frames * 1_000_000 / 48000)) > 50_000 { audioClock = nil }
        if audioClock == nil { audioClock = (origin: micro, frames: 0) }
        guard var clock = audioClock else { return }
        let pts = clock.origin + clock.frames * 1_000_000 / 48000
        clock.frames += Int64(converted.frameLength); audioClock = clock
        var packet = Data(capacity: 9 + Int(converted.frameLength) * 4); packet.append(5)
        packet.append(contentsOf: Self.bigEndian(UInt64(max(0, pts))))
        packet.append(UnsafeBufferPointer(start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: Int(converted.frameLength) * 4))
        onPacket?(packet)
    }

    func cancel() {
        cancelled = true; onPacket = nil; onError = nil
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
}
