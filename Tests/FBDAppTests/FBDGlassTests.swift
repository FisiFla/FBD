@testable import FBD
import XCTest

final class FBDGlassTests: XCTestCase {
    func testAvailabilityMatchesOS() {
        if #available(macOS 26, *) {
            #if compiler(>=6.2)
            XCTAssertTrue(FBDGlass.isAvailable)
            #endif
        } else {
            XCTAssertFalse(FBDGlass.isAvailable)
        }
    }

    func testThemeTokens() {
        XCTAssertEqual(FBDTheme.panelWidth, 340)
        XCTAssertEqual(FBDTheme.rowHeight, 32)
        XCTAssertEqual(FBDTheme.chipSize, 26)
        XCTAssertEqual(FBDTheme.tileSize, 44)
        XCTAssertEqual(FBDTheme.maxHeightFraction, 0.85)
    }
}
