import XCTest
@testable import NPCheck

final class NeoPlayNativeTests: XCTestCase {
    func testDiscoveryRestartDetachesPreviousBrowserAndRejectsLateErrors() {
        let first = NPRecordingBrowser(), second = NPRecordingBrowser()
        var pending = [first, second]
        let discovery = NPDiscovery(makeBrowser: { pending.removeFirst() })
        var failures = 0
        discovery.failed = { failures += 1 }
        discovery.start()
        XCTAssertEqual(first.searches, 1)
        discovery.start()
        XCTAssertEqual(first.stops, 1)
        XCTAssertNil(first.delegate)
        XCTAssertEqual(second.searches, 1)
        let browserError: [String: NSNumber] = [NetService.errorDomain: 10, NetService.errorCode: -72008]
        discovery.netServiceBrowser(first, didNotSearch: browserError)
        XCTAssertEqual(failures, 0)
        discovery.netServiceBrowser(second, didNotSearch: browserError)
        XCTAssertEqual(failures, 1)
        discovery.stop()
        discovery.netServiceBrowser(second, didNotSearch: browserError)
        XCTAssertEqual(failures, 1)
    }
    func testStoppedDiscoveryRejectsLateServiceResolution() {
        let browser = NPRecordingBrowser()
        let discovery = NPDiscovery(makeBrowser: { browser })
        var changes = 0
        discovery.changed = { changes += 1 }
        discovery.start()
        let service = NetService(domain: "local.", type: "_neoplay._tcp.", name: "fixture", port: 0)
        discovery.stop()
        let stoppedChanges = changes
        discovery.netServiceDidResolveAddress(service)
        XCTAssertEqual(changes, stoppedChanges)
        XCTAssertTrue(discovery.receivers.isEmpty)
    }
    func testGeometryKeepsAspectAndBounds() {
        XCTAssertEqual(NPPolicy.encodeSize(source: NPSize(width:640,height:480), display:NPSize(width:1920,height:1080)), NPSize(width:640,height:480))
        // A small receiver window must not shrink the picture: an iPhone 15 Pro in landscape
        // mirrored into a 1280-px window still encodes at the 1920 cap.
        XCTAssertEqual(NPPolicy.encodeSize(source: NPSize(width:2556,height:1179), display:NPSize(width:1280,height:588)), NPSize(width:1920,height:884))
        XCTAssertEqual(NPPolicy.bitrate(for: NPSize(width:1920,height:884)), 20_367_360)
        XCTAssertEqual(NPPolicy.bitrate(for: NPSize(width:640,height:480)), 8_000_000)
        XCTAssertEqual(NPPolicy.bitrate(for: NPSize(width:1920,height:1080)), 24_883_200)
        XCTAssertEqual(NPPolicy.bitrate(for: NPSize(width:1280,height:720), cast: true), 11_059_200)
        let wide = NPPolicy.encodeSize(source: NPSize(width:3840,height:2160), display:NPSize(width:3440,height:1440))
        XCTAssertEqual(wide, NPSize(width:1920,height:1080))
        let portrait = NPPolicy.encodeSize(source: NPSize(width:1080,height:1920), display:NPSize(width:1920,height:1080))
        XCTAssertEqual(portrait, NPSize(width:606,height:1080))
    }
    func testChromecastRetainsRecentPayloadsAfterPlaylistEviction() throws {
        let store = NPSegmentStore()
        try store.initialize(Data([1,2,3]))
        for _ in 0..<14 { try store.append(Data([1,2,3,4]), duration:1.01) }
        let playlist = String(data:store.response("index.m3u8").2, encoding:.utf8)!
        XCTAssertTrue(playlist.contains("#EXT-X-MEDIA-SEQUENCE:8"))
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:1"))
        XCTAssertFalse(playlist.contains("segment-0.m4s"))
        XCTAssertEqual(store.response("segment-0.m4s").0,200)
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
        XCTAssertTrue(first.contains("#EXT-X-TARGETDURATION:1")); XCTAssertTrue(first.contains("#EXT-X-MAP:URI=\"init-0.mp4\""))
        try store.initialize(Data([4,5,6])); try store.append(Data(repeating:2,count:20),duration:1)
        XCTAssertTrue(String(data:store.response("index.m3u8").2,encoding:.utf8)!.contains("#EXT-X-DISCONTINUITY\n"))
        for _ in 0..<4 { try store.append(Data(repeating:2,count:20),duration:1) }
        XCTAssertEqual(store.count,4); XCTAssertLessThanOrEqual(store.byteCount,1024)
        XCTAssertEqual(store.response("segment-0.m4s").0,404); XCTAssertEqual(store.response("init-0.mp4").0,404)
        XCTAssertEqual(store.response("../secrets").0,404)
        XCTAssertThrowsError(try store.append(Data([1]),duration:Double.nan))
        XCTAssertThrowsError(try store.append(Data([1]),duration:1.5))
        XCTAssertTrue(String(data:store.response("index.m3u8").2,encoding:.utf8)!.contains("#EXT-X-TARGETDURATION:1"))
    }
}

private final class NPRecordingBrowser: NetServiceBrowser {
    var searches = 0
    var stops = 0
    override func searchForServices(ofType type: String, inDomain domainString: String) {
        XCTAssertEqual(type, "_neoplay._tcp."); XCTAssertEqual(domainString, "local.")
        searches += 1
    }
    override func stop() { stops += 1 }
}
