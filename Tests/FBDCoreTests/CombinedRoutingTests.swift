import XCTest
@testable import FBDCore

final class CombinedRoutingTests: XCTestCase {
    // Hardware ceiling 500 nits, combined top 1600 nits (built-in XDR scenario).
    private let hardware = 500
    private let maxNits = 1600

    func testZeroMapsToHardwareZero() {
        XCTAssertEqual(CombinedRouting.route(value: 0, hardwareMaxNits: hardware, maxNits: maxNits), .hardware(0))
    }

    func testFullSliderMapsToXDRTarget() {
        XCTAssertEqual(CombinedRouting.route(value: 1, hardwareMaxNits: hardware, maxNits: maxNits), .xdr(1600))
    }

    func testHardwarePortionIsLinear() {
        // 0.25 of 1600 = 400 nits → 80 % of the 500-nit hardware ceiling.
        XCTAssertEqual(CombinedRouting.route(value: 0.25, hardwareMaxNits: hardware, maxNits: maxNits), .hardware(0.8))
    }

    func testBoundaryAtHardwareMaxStaysHardware() {
        // 500/1600 = 0.3125 → exactly the hardware ceiling.
        XCTAssertEqual(CombinedRouting.route(value: 0.3125, hardwareMaxNits: hardware, maxNits: maxNits), .hardware(1))
    }

    func testJustAboveHardwareMaxSwitchesToXDR() {
        // 0.313 of 1600 = 500.8 nits → XDR target 501.
        XCTAssertEqual(CombinedRouting.route(value: 0.313, hardwareMaxNits: hardware, maxNits: maxNits), .xdr(501))
    }

    func testNoXDRHeadroomStaysHardware() {
        // maxNits == hardwareMaxNits: nothing above hardware — full slider is 100 %.
        XCTAssertEqual(CombinedRouting.route(value: 1, hardwareMaxNits: hardware, maxNits: hardware), .hardware(1))
        XCTAssertEqual(CombinedRouting.route(value: 0.5, hardwareMaxNits: hardware, maxNits: hardware), .hardware(0.5))
    }

    func testOutOfRangeValuesAreClamped() {
        XCTAssertEqual(CombinedRouting.route(value: -0.5, hardwareMaxNits: hardware, maxNits: maxNits), .hardware(0))
        XCTAssertEqual(CombinedRouting.route(value: 2, hardwareMaxNits: hardware, maxNits: maxNits), .xdr(1600))
    }
}
