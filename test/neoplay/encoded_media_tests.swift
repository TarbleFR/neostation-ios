import XCTest
import AVFoundation
@testable import NPCheck

final class NeoPlayEncodedMediaTests: XCTestCase {
    struct Part: Codable { let initial: Bool; let duration: Double; let data: String }
    func testWindowsEncoderCarriesBothTracksOnOneTimeline() throws { try encodeFixture(cast: false) }
    func testChromecastEncoderCarriesBothTracksAndHLSMetadata() throws { try encodeFixture(cast: true) }
    private func encodeFixture(cast: Bool) throws {
        let muxer = try NPMuxer(source: NPSize(width: 640, height: 480), display: NPSize(width: 1920, height: 1080), cast: cast)
        let lock = NSLock(); var parts: [Part] = []; var failure: NPError?
        muxer.onError = { error in lock.lock(); failure = error; lock.unlock() }
        muxer.onSegment = { bytes, initial, duration in lock.lock(); parts.append(Part(initial: initial, duration: duration, data: bytes.base64EncodedString())); lock.unlock() }
        for frame in 0..<150 {
            let time = CMTime(value: Int64(frame + 300), timescale: 30)
            muxer.append(try video(frame: frame, time: time), video: true)
            muxer.append(try audio(frame: frame, time: time), video: false)
            Thread.sleep(forTimeInterval: 1.0 / 30.0)
        }
        let finished = expectation(description: "Encoder drained")
        muxer.finish { finished.fulfill() }
        wait(for: [finished], timeout: 10)
        lock.lock(); let output = parts; let error = failure; lock.unlock()
        XCTAssertNil(error); XCTAssertTrue(output.first?.initial == true)
        XCTAssertGreaterThanOrEqual(output.filter { !$0.initial }.count, cast ? 4 : 10)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("NeoPlayFixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = cast ? "chromecast" : "windows"
        try JSONEncoder().encode(output).write(to: directory.appendingPathComponent(name + ".json"))
        let merged = output.reduce(into: Data()) { $0.append(Data(base64Encoded: $1.data)!) }
        let file = directory.appendingPathComponent(name + ".mp4"); try merged.write(to: file)
        let asset = AVURLAsset(url: file)
        let videoTracks = asset.tracks(withMediaType: .video), audioTracks = asset.tracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1); XCTAssertEqual(audioTracks.count, 1)
        guard let vt = videoTracks.first, let at = audioTracks.first else { return }
        XCTAssertEqual(vt.naturalSize, CGSize(width: 640, height: 480))
        let v = try timing(asset, track: vt), a = try timing(asset, track: at)
        XCTAssertGreaterThan(v.count, 100); XCTAssertGreaterThan(a.count, 100)
        XCTAssertLessThan(abs(v.start - a.start), 0.1)
        XCTAssertLessThan(abs(v.end - a.end), 0.1)
        XCTAssertGreaterThan(v.end, 4.5)
        if cast {
            let store = NPSegmentStore()
            for part in output { let data = Data(base64Encoded: part.data)!; if part.initial { try store.initialize(data) } else { try store.append(data, duration: part.duration) } }
            XCTAssertEqual(store.response("index.m3u8").0, 200)
        }
    }
    private func timing(_ asset: AVAsset, track: AVAssetTrack) throws -> (start: Double, end: Double, count: Int) {
        let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        var start = Double.infinity, end = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
            start = min(start, pts); end = max(end, pts + (duration.isFinite ? duration : 0)); count += 1
        }
        XCTAssertEqual(reader.status, .completed)
        return (start, end, count)
    }
    private func video(frame: Int, time: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { throw NPError.encoder }
        CVPixelBufferLockBaseAddress(pixel, [])
        let row = CVPixelBufferGetBytesPerRow(pixel)
        let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<480 { for x in 0..<640 { let at = y * row + x * 4; bytes[at] = UInt8((frame * 3) % 255); bytes[at+1] = UInt8(x % 255); bytes[at+2] = UInt8(y % 255); bytes[at+3] = 255 } }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr, let format else { throw NPError.encoder }
        var info = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format, sampleTiming: &info, sampleBufferOut: &sample) == noErr, let sample else { throw NPError.encoder }
        return sample
    }
    private func audio(frame: Int, time: CMTime) throws -> CMSampleBuffer {
        var samples = [Int16](repeating: 0, count: 1600 * 2)
        for i in 0..<1600 { let value = Int16(sin(2 * .pi * 440 * Double(frame * 1600 + i) / 48000) * 8000); samples[i*2] = value; samples[i*2+1] = value }
        let data = samples.withUnsafeBytes { Data($0) }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { throw NPError.encoder }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == noErr else { throw NPError.encoder }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw NPError.encoder }
        var info = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = 4, sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1600, sampleTimingEntryCount: 1, sampleTimingArray: &info, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { throw NPError.encoder }
        return sample
    }
}
