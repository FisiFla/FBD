import XCTest
@testable import FBDCore

/// Registry shapes below are measured on an M-series MacBook Pro (macOS 27) with an LG TV on
/// HDMI: each external `AppleCLCD2` sits under `dispextN` and carries only an `EDID UUID` plus
/// nested `DisplayAttributes` (no flat vendor/product keys); its `DCPAVServiceProxy` sits under
/// the following `dcpextN` sibling, not under the framebuffer.
final class AVServiceMatchingTests: XCTestCase {
    // CG reports vendor 0x1E6D, model 0xC0C8, serial 0x01010101 for this display.
    private let lgUUID = "1E6DC8C0-0000-0000-0120-010380A05A78"

    func testEDIDUUIDMatchesVendorAndLittleEndianProduct() {
        XCTAssertTrue(IOAVServiceAPI.edidUUID(lgUUID, matchesVendor: 0x1E6D, model: 0xC0C8))
        XCTAssertFalse(IOAVServiceAPI.edidUUID(lgUUID, matchesVendor: 0x1E6D, model: 0xC8C0))
        XCTAssertFalse(IOAVServiceAPI.edidUUID(lgUUID, matchesVendor: 0x0610, model: 0xC0C8))
        XCTAssertFalse(IOAVServiceAPI.edidUUID("garbage", matchesVendor: 0x1E6D, model: 0xC0C8))
    }

    func testFramebufferMatchesByEDIDUUID() {
        let props: [String: Any] = ["EDID UUID": lgUUID]
        XCTAssertTrue(IOAVServiceAPI.framebufferMatches(props, vendor: 0x1E6D, model: 0xC0C8, serial: 0x01010101))
        XCTAssertFalse(IOAVServiceAPI.framebufferMatches(props, vendor: 0x1E6D, model: 0x1234, serial: 0))
    }

    func testFramebufferStillMatchesLegacyFlatKeys() {
        let props: [String: Any] = ["DisplayVendorID": UInt32(0x10AC), "DisplayProductID": UInt32(0xA0C4)]
        XCTAssertTrue(IOAVServiceAPI.framebufferMatches(props, vendor: 0x10AC, model: 0xA0C4, serial: 0))
    }

    func testPairsFramebufferWithFollowingExternalProxy() {
        let nodes: [IOAVServiceAPI.RegistryNode] = [
            .init(className: "AppleCLCD2", props: [:]),                                  // built-in
            .init(className: "DCPAVServiceProxy", props: ["Location": "Embedded"]),
            .init(className: "AppleCLCD2", props: ["EDID UUID": lgUUID]),                // dispext0
            .init(className: "DCPAVServiceProxy", props: ["Location": "External"]),      // dcpext0
            .init(className: "AppleCLCD2", props: [:]),                                  // dispext1, empty
            .init(className: "DCPAVServiceProxy", props: ["Location": "External"]),
        ]
        XCTAssertEqual(IOAVServiceAPI.proxyIndex(in: nodes, vendor: 0x1E6D, model: 0xC0C8, serial: 0x01010101), 3)
    }

    func testNoProxyWhenFramebufferHasNoFollowingExternalProxy() {
        let nodes: [IOAVServiceAPI.RegistryNode] = [
            .init(className: "AppleCLCD2", props: ["EDID UUID": lgUUID]),
            .init(className: "AppleCLCD2", props: [:]),
            .init(className: "DCPAVServiceProxy", props: ["Location": "External"]),  // belongs to the second one
        ]
        XCTAssertNil(IOAVServiceAPI.proxyIndex(in: nodes, vendor: 0x1E6D, model: 0xC0C8, serial: 0))
    }

    func testEmbeddedProxyIsNeverPaired() {
        let nodes: [IOAVServiceAPI.RegistryNode] = [
            .init(className: "AppleCLCD2", props: ["EDID UUID": lgUUID]),
            .init(className: "DCPAVServiceProxy", props: ["Location": "Embedded"]),
        ]
        XCTAssertNil(IOAVServiceAPI.proxyIndex(in: nodes, vendor: 0x1E6D, model: 0xC0C8, serial: 0))
    }
}
