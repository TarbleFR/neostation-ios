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
        lock.lock(); let output = packets; let error = failure; lock.unlock()
        XCTAssertNil(error)
        let kinds = output.map { Int($0[0]) }
        print("NEOPLAY_FRAMES kinds=\(Dictionary(grouping: kinds, by: { $0 }).mapValues(\.count)) bytes=\(output.reduce(0) { $0 + $1.count })")
        XCTAssertEqual(kinds.first, 3, "configuration first")
        let config = output[0]
        XCTAssertEqual(Int(config[1]) << 8 | Int(config[2]), 640); XCTAssertEqual(Int(config[3]) << 8 | Int(config[4]), 480)
        XCTAssertEqual(config[9], 2); XCTAssertEqual(config[10], 1, "avcC version")
        let video = output.filter { $0[0] == 4 }, audio = output.filter { $0[0] == 5 }
        XCTAssertGreaterThanOrEqual(video.count, 140); XCTAssertGreaterThanOrEqual(audio.count, 100)
        XCTAssertEqual(video.first?[9], 1, "first picture is a key picture")
        let pts = video.map { $0.subdata(in: 1..<9).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        XCTAssertEqual(pts, pts.sorted()); XCTAssertEqual(Set(pts).count, pts.count)
        XCTAssertGreaterThan(pts.last ?? 0, 4_500_000)
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
            return Packet(kind: kind, end: end, data: packet.base64EncodedString())
        }
        try JSONEncoder().encode(fixture).write(to: directory.appendingPathComponent("frames.json"))
    }
}
