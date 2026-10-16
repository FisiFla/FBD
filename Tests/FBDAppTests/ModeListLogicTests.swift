@testable import FBD
import FBDCore
import XCTest

final class ModeListLogicTests: XCTestCase {
    func testCurrentModeAlwaysPresent() throws {
        let modes = try XCTUnwrap(DisplayModeFixtures.macBookAir())
        let current = modes.last!
        XCTAssertTrue(ModeListLogic.curated(modes: modes, current: current).contains(current))
    }

    func testCuratedHasOneRowPerLogicalSize() throws {
        let modes = try XCTUnwrap(DisplayModeFixtures.macBookAir())
        let curated = ModeListLogic.curated(modes: modes, current: modes[0])
        let sizes = curated.map { "\($0.width)x\($0.height)" }
        XCTAssertEqual(sizes.count, Set(sizes).count)
    }

    func testRefreshRatesDeduplicatedAndSorted() throws {
        let modes = try XCTUnwrap(DisplayModeFixtures.macBookAir())
        let rates = ModeListLogic.refreshRates(modes: modes, current: modes[0])
        XCTAssertEqual(rates, rates.sorted(by: >))
        XCTAssertEqual(rates.count, Set(rates).count)
    }

    /// Only rates the current size actually offers: a rate from another size would be a row
    /// that does nothing when picked.
    func testRefreshRatesAreTheCurrentSizes() throws {
        let modes = try XCTUnwrap(DisplayModeFixtures.macBookAir())
        XCTAssertEqual(ModeListLogic.refreshRates(modes: modes, current: modes[0]), [60, 50, 48])
        XCTAssertEqual(ModeListLogic.refreshRates(modes: modes, current: modes[2]), [60])
        XCTAssertEqual(ModeListLogic.refreshRates(modes: modes, current: nil), [])
    }

    func testModeForRefreshRateKeepsSizeAndHiDPI() throws {
        let modes = try XCTUnwrap(DisplayModeFixtures.macBookAir())
        XCTAssertEqual(ModeListLogic.mode(refreshRate: 50, modes: modes, current: modes[0])?.modeNumber, 7)
        XCTAssertNil(ModeListLogic.mode(refreshRate: 50, modes: modes, current: modes[1]))
    }

    func testRateLabel() {
        XCTAssertEqual(ModeListLogic.rateLabel(60), "60 Hz")
        XCTAssertEqual(ModeListLogic.rateLabel(59.94), "59.94 Hz")
    }
}
