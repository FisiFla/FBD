import XCTest
@testable import FBDCore

/// The live DPCD read path's one pure part: the request bounds.
///
/// The entry point clamps the length to 0x1000 itself, which means an oversized request is silently
/// *truncated* rather than refused — a caller could then believe it read more than it did. The
/// request refuses instead, and these are the cases that pins.
final class DPCDRequestTests: XCTestCase {
    func testAUsualRequestIsAccepted() {
        let request = DPCDRequest(address: 0x0000, length: 16)
        XCTAssertEqual(request?.address, 0x0000)
        XCTAssertEqual(request?.length, 16)
    }

    func testTheCapabilityBlockAddressIsZero() {
        XCTAssertEqual(DPCDRequest.receiverCapabilityAddress, 0x0000)
    }

    /// The implementation's own clamp, restated here so the two cannot drift apart silently.
    func testTheLongestRequestIsTheImplementationsClamp() {
        XCTAssertEqual(DPCDRequest.maxLength, 4096)
        XCTAssertNotNil(DPCDRequest(address: 0x0000, length: DPCDRequest.maxLength))
        XCTAssertNil(DPCDRequest(address: 0x0000, length: DPCDRequest.maxLength + 1))
    }

    /// Refused, not clamped: a caller asking for more than can be read has to be told, not quietly
    /// given less.
    func testAnOversizedOrEmptyRequestIsRefusedRatherThanClamped() {
        XCTAssertNil(DPCDRequest(address: 0x0000, length: 0))
        XCTAssertNil(DPCDRequest(address: 0x0000, length: -1))
        XCTAssertNil(DPCDRequest(address: 0x0000, length: 9_999))
    }

    /// HDCP's BSTATUS sits far from the capability block, which is why the address is the caller's
    /// to choose rather than fixed.
    func testAnAddressFarFromTheCapabilityBlockIsAccepted() {
        XCTAssertEqual(DPCDRequest(address: 0x68028, length: 1)?.address, 0x68028)
    }
}
