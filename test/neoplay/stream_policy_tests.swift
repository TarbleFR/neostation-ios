import XCTest
@testable import NPCheck

// Build410: receiver ceilings, link tiers and the adapter that moves between them.
final class NeoPlayStreamPolicyTests: XCTestCase {
    // Post-410: a receiver window resize or full screen only reports a new
    // display size; the sender's encoded size depends on the capture and the
    // ceiling alone, so NPCapture.restartEncodersIfOutputChanges finds nothing
    // to restart and neither the pictures nor the sound are interrupted.
    func testEncodedSizeNeverFollowsTheReceiverWindowSoResizeAndFullScreenRestartNothing() {
        let phone = NPSize(width: 2868, height: 1320)
        let windows = [NPSize(width: 640, height: 360), NPSize(width: 1280, height: 720), NPSize(width: 1920, height: 1080), NPSize(width: 2560, height: 1440), NPSize(width: 3840, height: 2160), NPSize(width: 7680, height: 4320)]
        for (tier, receiverMax) in [(NPPolicy.Tier.native, NPPolicy.nativeCap), (.full, NPPolicy.nativeCap), (.half, NPPolicy.nativeCap), (.native, NPPolicy.legacyCap)] {
            let cap = NPPolicy.cap(tier: tier, receiverMax: receiverMax)
            let sizes = windows.map { NPPolicy.encodeSize(source: phone, display: $0, cap: cap) }
            XCTAssertTrue(sizes.allSatisfy { $0 == sizes[0] }, "tier \(tier): every window size encodes \(sizes[0]), got \(sizes)")
        }
        XCTAssertEqual(NPPolicy.encodeSize(source: phone, display: NPSize(width: 640, height: 360), cap: NPPolicy.cap(tier: .native, receiverMax: NPPolicy.nativeCap)), phone, "a small window still receives the native capture")
        XCTAssertEqual(NPPolicy.encodeSize(source: phone, display: NPSize(width: 7680, height: 4320), cap: NPPolicy.cap(tier: .native, receiverMax: NPPolicy.legacyCap)), NPSize(width: 1920, height: 882), "a MediaSource receiver keeps its 1080p ceiling whatever its window")
    }
    func testFramesReceiverDecodesTheNativeCaptureAndMediaSourceKeeps1080p() {
        let phone = NPSize(width: 2868, height: 1320) // iPhone 16 Pro Max display, ReplayKit bound
        let frames = NPPolicy.cap(tier: .native, receiverMax: NPSize(width: 7680, height: 4320))
        XCTAssertEqual(NPPolicy.encodeSize(source: phone, display: NPSize(width: 3840, height: 2160), cap: frames), phone)
        XCTAssertEqual(NPPolicy.bitrate(for: phone), 45_429_120)
        let legacy = NPPolicy.cap(tier: .native, receiverMax: NPPolicy.legacyCap)
        XCTAssertEqual(NPPolicy.encodeSize(source: phone, display: NPSize(width: 3840, height: 2160), cap: legacy), NPSize(width: 1920, height: 882))
        // A receiver limited to 1440p is honoured even on the native tier.
        XCTAssertEqual(NPPolicy.cap(tier: .native, receiverMax: NPSize(width: 2560, height: 1440)), NPSize(width: 2560, height: 1440))
        XCTAssertEqual(NPPolicy.cap(tier: .full, receiverMax: NPSize(width: 7680, height: 4320)), NPSize(width: 1920, height: 1080))
        XCTAssertEqual(NPPolicy.cap(tier: .half, receiverMax: NPSize(width: 7680, height: 4320)), NPSize(width: 1280, height: 720))
        XCTAssertEqual(NPPolicy.cap(tier: .half, receiverMax: NPSize(width: 640, height: 480)), NPSize(width: 640, height: 480))
        XCTAssertEqual(NPPolicy.bitrate(for: NPSize(width: 7680, height: 4320)), 60_000_000)
        XCTAssertEqual(NPPolicy.bitrate(for: NPSize(width: 1280, height: 720), cast: true), 11_059_200)
    }
    func testLinkAdapterStepsDownOnRepeatedShedsAndRecoversAfterQuiet() {
        var adapter = NPLinkAdapter()
        XCTAssertEqual(adapter.tier, .native)
        XCTAssertNil(adapter.shed(at: 100)); XCTAssertNil(adapter.shed(at: 100.5))
        XCTAssertEqual(adapter.shed(at: 101), .full)            // third shed inside two seconds
        XCTAssertNil(adapter.shed(at: 101.1)); XCTAssertNil(adapter.shed(at: 101.2)); XCTAssertNil(adapter.shed(at: 101.3)) // cooldown
        XCTAssertEqual(adapter.shed(at: 107, count: 3), .half)  // after the cooldown, a burst of three
        XCTAssertNil(adapter.shed(at: 108, count: 10))          // nothing below half
        XCTAssertEqual(adapter.tier, .half)
        XCTAssertNil(adapter.tick(at: 120))                     // sheds still recent
        XCTAssertEqual(adapter.tick(at: 128.5), .full)          // twenty quiet seconds
        XCTAssertNil(adapter.tick(at: 130))
        XCTAssertEqual(adapter.tick(at: 149), .native)
        XCTAssertNil(adapter.tick(at: 200))
        // Old sheds outside the window do not count.
        var fresh = NPLinkAdapter()
        XCTAssertNil(fresh.shed(at: 0)); XCTAssertNil(fresh.shed(at: 0.1)); XCTAssertNil(fresh.shed(at: 5))
        XCTAssertEqual(fresh.tier, .native)
    }
    func testSessionFenceAndSegmentStoreUnchanged() {
        var fence = NPSessionFence(); let token = fence.begin()!
        XCTAssertTrue(fence.accepts(token)); fence.stop(); XCTAssertFalse(fence.accepts(token))
    }
}
