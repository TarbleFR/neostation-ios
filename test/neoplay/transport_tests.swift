import XCTest
@testable import NPCheck

// Build410: the receiver's control messages drive the transport's callbacks
// without a socket. `ready` is answered once, `display` every time, `playback`
// only when playing, and `keyframe` (a viewer behind its decoder) asks for a
// key picture.
final class NeoPlayTransportMessageTests: XCTestCase {
    func testPairingAddsTheGuardedEncoderPromiseWithoutChangingVersionOrPin() throws {
        let data = try NPWindowsTransport.pairingBody(pin: "001234")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["pin"] as? String, "001234")
        XCTAssertEqual(object["noFrameReordering"] as? Bool, true)
        XCTAssertEqual(Set(object.keys), ["v", "pin", "noFrameReordering"])
    }
    func testReadyPublishesTheReceiverProtocolAndCeilingOnce() {
        let transport = NPWindowsTransport()
        var ready: [NPSize] = []
        transport.onReady = { ready.append($0) }
        transport.handle(["type": "ready", "v": 1, "frames": true, "width": 3840, "height": 2160, "maxWidth": 7680, "maxHeight": 4320])
        XCTAssertEqual(ready, [NPSize(width: 3840, height: 2160)])
        XCTAssertTrue(transport.framesSupported)
        XCTAssertEqual(transport.receiverMax, NPSize(width: 7680, height: 4320))
        transport.handle(["type": "ready", "v": 1, "width": 1920, "height": 1080])
        XCTAssertEqual(ready.count, 1, "ready is answered once per connection")
        XCTAssertFalse(transport.framesSupported)
        XCTAssertEqual(transport.receiverMax, NPPolicy.legacyCap, "a MediaSource receiver keeps the 1080p ceiling")
    }
    func testDisplayPlaybackAndKeyRequestsReachTheirCallbacks() {
        let transport = NPWindowsTransport()
        var displays: [NPSize] = [], playing = 0, keys = 0
        transport.onDisplay = { displays.append($0) }
        transport.onPlayback = { playing += 1 }
        transport.onKeyRequest = { keys += 1 }
        transport.handle(["type": "display", "width": 3440, "height": 1440])
        transport.handle(["type": "display", "width": 100_000, "height": 0])
        XCTAssertEqual(displays, [NPSize(width: 3440, height: 1440), NPSize(width: 7680, height: 2)], "sizes are clamped to the protocol bounds")
        transport.handle(["type": "playback", "playing": false])
        XCTAssertEqual(playing, 0)
        transport.handle(["type": "playback", "playing": true])
        XCTAssertEqual(playing, 1)
        transport.handle(["type": "keyframe"]); transport.handle(["type": "keyframe"])
        XCTAssertEqual(keys, 2)
        transport.handle(["type": "unknown"]); transport.handle([:])
        XCTAssertEqual(displays.count, 2); XCTAssertEqual(playing, 1); XCTAssertEqual(keys, 2)
    }
}
