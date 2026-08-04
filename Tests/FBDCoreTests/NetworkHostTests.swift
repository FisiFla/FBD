import XCTest
@testable import FBDCore

final class NetworkHostTests: XCTestCase {
    func testBracketsIPv6Literal() {
        XCTAssertEqual(NetworkHost.bracketed("fe80::1"), "[fe80::1]")
    }

    func testPassesThroughAlreadyBracketed() {
        XCTAssertEqual(NetworkHost.bracketed("[fe80::1]"), "[fe80::1]")
    }

    func testPassesThroughIPv4AndHostnames() {
        XCTAssertEqual(NetworkHost.bracketed("192.168.0.5"), "192.168.0.5")
        XCTAssertEqual(NetworkHost.bracketed("tv.local"), "tv.local")
    }
}
