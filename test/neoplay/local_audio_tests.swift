import XCTest
@testable import NPCheck

private final class NeoPlayVolumeProbe: NPVolumeOutput {
    var volume: Float = 0.63
    var writable = true
    var delayed = false
    var writes: [Float] = []
    func setVolume(_ value: Float) -> Bool {
        guard writable else { return false }
        writes.append(value)
        if !delayed { volume = value }
        return true
    }
}

final class NeoPlayLocalAudioTests: XCTestCase {
    func testLeaseMutesEnforcesAndRestoresOriginalOutput() {
        let output = NeoPlayVolumeProbe(), lease = NPLocalAudioLease(output: output)
        XCTAssertTrue(lease.begin())
        let token = lease.generation
        XCTAssertEqual(output.volume, 0)
        XCTAssertTrue(lease.verify(token))
        output.volume = 0.2
        XCTAssertTrue(lease.enforce(token))
        XCTAssertEqual(output.volume, 0)
        XCTAssertTrue(lease.end())
        XCTAssertEqual(output.volume, 0.63)
        XCTAssertFalse(lease.active)
    }

    func testFailedRestoreRetainsLeaseForRetry() {
        let output = NeoPlayVolumeProbe(), lease = NPLocalAudioLease(output: output)
        XCTAssertTrue(lease.begin())
        output.writable = false
        XCTAssertFalse(lease.end())
        XCTAssertTrue(lease.active)
        output.writable = true
        XCTAssertTrue(lease.end())
        XCTAssertEqual(output.volume, 0.63)
    }

    func testDelayedMuteIsCounteredByImmediateStop() {
        let output = NeoPlayVolumeProbe()
        output.delayed = true
        let lease = NPLocalAudioLease(output: output)
        XCTAssertTrue(lease.begin())
        XCTAssertTrue(lease.end())
        XCTAssertEqual(output.writes, [0, 0.63])
    }
}
