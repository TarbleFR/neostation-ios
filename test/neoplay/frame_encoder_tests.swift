import XCTest
import AVFoundation
@testable import NPCheck

// NeoPlay v2 frame protocol: one packet per picture out of VideoToolbox, raw PCM.
// Also writes frames.json (the Windows receiver bench format) so the exact bytes
// an iOS encoder produces can be replayed through the receiver on Windows.
final class NeoPlayFrameEncoderTests: XCTestCase {
    struct Packet: Codable { let kind: Int; let end: Double; let data: String }
    func testFrameEncoderEmitsConfigThenKeyPictureThenPicturesAndPCM() throws {
        let encoder = try NPFrameEncoder(source: NPSize(width: 640, height: 480), display: NPSize(width: 1920, height: 1080))
        let lock = NSLock(); var packets: [Data] = []; var failure: NPError?
        encoder.onError = { error in lock.lock(); failure = error; lock.unlock() }
        encoder.onPacket = { packet in lock.lock(); packets.append(packet); lock.unlock() }
        let helper = NeoPlayEncodedMediaTests()
        for frame in 0..<150 {
            let time = CMTime(value: Int64(frame + 300), timescale: 30)
            encoder.append(try helper.makeVideo(frame: frame, time: time), video: true)
            encoder.append(try helper.makeAudio(frame: frame, time: time), video: false)
            Thread.sleep(forTimeInterval: 1.0 / 30.0)
        }
        Thread.sleep(forTimeInterval: 0.5)
        encoder.cancel()
        // Build410: a link tier change recreates the encoder on the same session
        // timeline (320x240 ceiling); the receiver must reconfigure in place and
        // keep playing sound across the second configuration.
        let lower = try NPFrameEncoder(source: NPSize(width: 640, height: 480), display: NPSize(width: 1920, height: 1080), cap: NPSize(width: 320, height: 240), origin: encoder.sessionOrigin)
        XCTAssertEqual(lower.output, NPSize(width: 320, height: 240))
        lower.onError = { error in lock.lock(); failure = error; lock.unlock() }
        lower.onPacket = { packet in lock.lock(); packets.append(packet); lock.unlock() }
        for frame in 150..<210 {
            let time = CMTime(value: Int64(frame + 300), timescale: 30)
            lower.append(try helper.makeVideo(frame: frame, time: time), video: true)
            lower.append(try helper.makeAudio(frame: frame, time: time), video: false)
            Thread.sleep(forTimeInterval: 1.0 / 30.0)
        }
        Thread.sleep(forTimeInterval: 0.5)
        lower.cancel()
        lock.lock(); let output = packets; let error = failure; lock.unlock()
        XCTAssertNil(error)
        let kinds = output.map { Int($0[0]) }
        print("NEOPLAY_FRAMES kinds=\(Dictionary(grouping: kinds, by: { $0 }).mapValues(\.count)) bytes=\(output.reduce(0) { $0 + $1.count })")
        XCTAssertEqual(kinds.first, 3, "configuration first")
        let configs = output.filter { $0[0] == 3 }
        XCTAssertEqual(configs.count, 2, "one configuration per encoder of the session")
        let config = configs[0], second = configs[1]
        XCTAssertEqual(Int(config[1]) << 8 | Int(config[2]), 640); XCTAssertEqual(Int(config[3]) << 8 | Int(config[4]), 480)
        XCTAssertEqual(Int(second[1]) << 8 | Int(second[2]), 320); XCTAssertEqual(Int(second[3]) << 8 | Int(second[4]), 240)
        XCTAssertEqual(config[9], 2); XCTAssertEqual(config[10], 1, "avcC version")
        let video = output.filter { $0[0] == 4 }, audio = output.filter { $0[0] == 5 }
        let pts = video.map { $0.subdata(in: 1..<9).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        let indexes = pts.map { Int(($0 * 30 + 500_000) / 1_000_000) }
        print("NEOPLAY_FRAMES first=\(indexes.first ?? -1) last=\(indexes.last ?? -1) missing=\((0..<210).filter { !indexes.contains($0) })")
        // Every submitted picture comes out: cancel() flushes the pictures VideoToolbox still holds before invalidating the session.
        XCTAssertGreaterThanOrEqual(video.count, 206, "pictures in flight are flushed, not discarded, when an encoder is retired")
        XCTAssertGreaterThanOrEqual(audio.count, 150) // sound before each encoder's first picture (its configuration) is dropped by design
        XCTAssertEqual(video.first?[9], 1, "first picture is a key picture")
        XCTAssertEqual(pts, pts.sorted(), "one timeline across both encoders"); XCTAssertEqual(Set(pts).count, pts.count)
        XCTAssertGreaterThan(pts.last ?? 0, 6_500_000)
        let audioPts = audio.map { $0.subdata(in: 1..<9).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        XCTAssertEqual(audioPts, audioPts.sorted(), "sound never restarts at a tier change")
        // Every picture: 4-byte NAL lengths that tile the access unit exactly.
        for packet in video {
            var at = 10; var nals = 0
            while at + 4 <= packet.count { let size = packet.subdata(in: at..<at + 4).reduce(0) { $0 << 8 | Int($1) }; at += 4 + size; nals += 1 }
            XCTAssertEqual(at, packet.count); XCTAssertGreaterThan(nals, 0)
        }
        XCTAssertEqual(audio.first.map { ($0.count - 9) % 4 }, 0)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("NeoPlayFixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("NEOPLAY_FIXTURE_PATH:\(directory.path)")
        let fixture = output.map { packet -> Packet in
            let kind = Int(packet[0])
            let micro = kind == 3 ? 0 : packet.subdata(in: 1..<9).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let end = Double(micro) / 1_000_000 + (kind == 4 ? 1.0 / 30 : kind == 5 ? Double((packet.count - 9) / 4) / 48000 : 0)
            // A later configuration is paced like the picture that follows it (its own `end` is 0 otherwise).
            return Packet(kind: kind, end: end, data: packet.base64EncodedString())
        }
        try JSONEncoder().encode(fixture).write(to: directory.appendingPathComponent("frames.json"))
    }
}

// Build410: sound and pictures reach the encoder from different queues; the
// PCM timeline stays contiguous, every packet is well-formed, a requested key
// picture arrives, and a native-size cap encodes the capture size untouched.
final class NeoPlayFrameEncoderConcurrencyTests: XCTestCase {
    func testAudioFromItsOwnQueueStaysContiguousWhilePicturesEncode() throws {
        let encoder = try NPFrameEncoder(source: NPSize(width: 640, height: 480), display: NPSize(width: 1920, height: 1080), cap: NPPolicy.cap(tier: .native, receiverMax: NPPolicy.nativeCap))
        XCTAssertEqual(encoder.output, NPSize(width: 640, height: 480))
        let lock = NSLock(); var packets: [Data] = []; var failure: NPError?
        encoder.onError = { error in lock.lock(); failure = error; lock.unlock() }
        encoder.onPacket = { packet in lock.lock(); packets.append(packet); lock.unlock() }
        let helper = NeoPlayEncodedMediaTests()
        let video = DispatchQueue(label: "test.capture"), audio = DispatchQueue(label: "test.audio")
        let group = DispatchGroup()
        group.enter(); video.async {
            for frame in 0..<120 {
                let time = CMTime(value: Int64(frame + 300), timescale: 30)
                if let sample = try? helper.makeVideo(frame: frame, time: time) { encoder.append(sample, video: true) }
                if frame == 60 { encoder.requestKeyFrame() }
                Thread.sleep(forTimeInterval: 1.0 / 30.0)
            }
            group.leave()
        }
        group.enter(); audio.async {
            Thread.sleep(forTimeInterval: 0.2) // the anchor is the first picture; the configuration follows the first key picture
            for frame in 0..<120 {
                let time = CMTime(value: Int64(frame + 306), timescale: 30)
                if let sample = try? helper.makeAudio(frame: frame, time: time) { encoder.append(sample, video: false) }
                Thread.sleep(forTimeInterval: 1.0 / 30.0)
            }
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        Thread.sleep(forTimeInterval: 0.5)
        encoder.cancel()
        lock.lock(); let output = packets; let error = failure; lock.unlock()
        XCTAssertNil(error)
        let pictures = output.filter { $0[0] == 4 }, sound = output.filter { $0[0] == 5 }
        XCTAssertGreaterThanOrEqual(pictures.count, 100); XCTAssertGreaterThanOrEqual(sound.count, 90)
        XCTAssertGreaterThanOrEqual(pictures.filter { $0[9] == 1 }.count, 2, "initial key picture and the requested one")
        // PCM packets tile the timeline: each starts where the previous one ended (48 kHz frame counter).
        var expected: UInt64?
        for packet in sound {
            let pts = packet.subdata(in: 1..<9).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let frames = UInt64((packet.count - 9) / 4)
            if let expected { XCTAssertLessThanOrEqual(pts > expected ? pts - expected : expected - pts, 25, "contiguous PCM timeline") }
            expected = pts + frames * 1_000_000 / 48000
        }
        XCTAssertEqual(encoder.reanchors, 0)
        XCTAssertEqual(encoder.audioPackets, sound.count)
    }
    func testSoundOfAnotherLayoutStaysContiguousAndIsDeliveredWithoutWaiting() throws {
        // ReplayKit commonly hands 44.1 kHz Float32 non-interleaved 1024-frame buffers; the encoder
        // converts them to 48 kHz s16 and emits each PCM packet before append returns (no hop).
        let encoder = try NPFrameEncoder(source: NPSize(width: 640, height: 480), display: NPSize(width: 640, height: 480), cap: NPPolicy.nativeCap)
        let lock = NSLock(); var packets: [Data] = []; var deliveredInsideAppend = 0; var inAppend = false
        encoder.onPacket = { packet in lock.lock(); packets.append(packet); if packet[0] == 5 && inAppend { deliveredInsideAppend += 1 }; lock.unlock() }
        let helper = NeoPlayEncodedMediaTests()
        for frame in 0..<30 { encoder.append(try helper.makeVideo(frame: frame, time: CMTime(value: Int64(frame + 300), timescale: 30)), video: true); Thread.sleep(forTimeInterval: 1.0 / 30.0) }
        Thread.sleep(forTimeInterval: 0.3)
        var position: Int64 = 0
        for _ in 0..<100 {
            let sample = try Self.makeFloatAudio(frames: 1024, rate: 44100, time: CMTime(value: 300 * 1470 + position, timescale: 44100))
            lock.lock(); inAppend = true; lock.unlock()
            encoder.append(sample, video: false)
            lock.lock(); inAppend = false; lock.unlock()
            position += 1024
        }
        encoder.cancel()
        lock.lock(); let sound = packets.filter { $0[0] == 5 }; let synchronous = deliveredInsideAppend; lock.unlock()
        XCTAssertGreaterThanOrEqual(sound.count, 90); XCTAssertEqual(synchronous, sound.count, "PCM leaves inside append, never behind a picture")
        var expected: UInt64?; var total: UInt64 = 0
        for packet in sound {
            let pts = packet.subdata(in: 1..<9).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let frames = UInt64((packet.count - 9) / 4); total += frames
            if let expected { XCTAssertLessThanOrEqual(pts > expected ? pts - expected : expected - pts, 25, "contiguous 48 kHz timeline from a 44.1 kHz source") }
            expected = pts + frames * 1_000_000 / 48000
        }
        XCTAssertEqual(encoder.reanchors, 0)
        // 100 x 1024 frames at 44.1 kHz = 2.32 s -> about 111,400 frames at 48 kHz, minus converter latency.
        XCTAssertGreaterThan(total, 105_000); XCTAssertLessThan(total, 112_000)
    }
    static func makeFloatAudio(frames: Int, rate: Double, time: CMTime) throws -> CMSampleBuffer {
        let channelBytes = frames * 4, length = channelBytes * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { throw NPError.encoder }
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { let value = Float(sin(2 * .pi * 440 * Double(i) / rate) * 0.25); samples[i] = value; samples[frames + i] = value } // planar: left plane then right plane
        let copied = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
        guard copied == noErr else { throw NPError.encoder }
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw NPError.encoder }
        var info = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = 4, sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &info, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { throw NPError.encoder }
        return sample
    }
    func testPassthroughEncodesNativeSizedUprightBuffersWithoutRendering() throws {
        let encoder = try NPFrameEncoder(source: NPSize(width: 640, height: 480), display: NPSize(width: 640, height: 480), cap: NPPolicy.nativeCap)
        let helper = NeoPlayEncodedMediaTests()
        for frame in 0..<10 { encoder.append(try helper.makeVideo(frame: frame, time: CMTime(value: Int64(frame + 300), timescale: 30)), video: true); Thread.sleep(forTimeInterval: 1.0 / 30.0) }
        Thread.sleep(forTimeInterval: 0.3); encoder.cancel()
        XCTAssertEqual(encoder.passthrough, 10)
    }
}
