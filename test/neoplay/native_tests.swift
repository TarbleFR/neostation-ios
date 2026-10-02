import XCTest
@testable import NPCheck

final class NeoPlayNativeTests: XCTestCase {
    func testGeometryKeepsAspectAndBounds() {
        XCTAssertEqual(NPPolicy.encodeSize(source: NPSize(width:640,height:480), display:NPSize(width:1920,height:1080)), NPSize(width:640,height:480))
        let wide = NPPolicy.encodeSize(source: NPSize(width:3840,height:2160), display:NPSize(width:3440,height:1440))
        XCTAssertEqual(wide, NPSize(width:1920,height:1080))
        let portrait = NPPolicy.encodeSize(source: NPSize(width:1080,height:1920), display:NPSize(width:1920,height:1080))
        XCTAssertEqual(portrait, NPSize(width:606,height:1080))
    }
    func testLateCallbacksDoNotReviveStoppedSession() {
        var fence = NPSessionFence(); let old = fence.begin()!
        XCTAssertNil(fence.begin()); fence.stop(); let current = fence.begin()!
        XCTAssertFalse(fence.accepts(old)); XCTAssertTrue(fence.accepts(current))
        fence.stop(); XCTAssertFalse(fence.accepts(current))
    }
    func testChromecastPlaylistEvictionAndOrientationDiscontinuity() throws {
        let store = NPSegmentStore(maxBytes:1024,maxSegments:4)
        XCTAssertEqual(store.response("index.m3u8").0,503)
        try store.initialize(Data([1,2,3]))
        for _ in 0..<3 { try store.append(Data(repeating:1,count:20),duration:1.01) }
        let first = String(data:store.response("index.m3u8").2,encoding:.utf8)!
        XCTAssertTrue(first.contains("#EXT-X-TARGETDURATION:2")); XCTAssertTrue(first.contains("#EXT-X-MAP:URI=\"init-0.mp4\""))
        try store.initialize(Data([4,5,6])); try store.append(Data(repeating:2,count:20),duration:1)
        XCTAssertTrue(String(data:store.response("index.m3u8").2,encoding:.utf8)!.contains("#EXT-X-DISCONTINUITY\n"))
        for _ in 0..<4 { try store.append(Data(repeating:2,count:20),duration:1) }
        XCTAssertEqual(store.count,4); XCTAssertLessThanOrEqual(store.byteCount,1024)
        XCTAssertEqual(store.response("segment-0.m4s").0,404); XCTAssertEqual(store.response("init-0.mp4").0,404)
        XCTAssertEqual(store.response("../secrets").0,404)
        XCTAssertThrowsError(try store.append(Data([1]),duration:Double.nan))
    }
}
