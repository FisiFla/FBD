@testable import FBD
import XCTest

final class HomePageTests: XCTestCase {
    func testDisplaySubtitle() {
        XCTAssertEqual(DisplayBlock.subtitle(width: 2560, height: 1440, hz: 59.94), "2560 × 1440 · 60 Hz")
        XCTAssertEqual(DisplayBlock.subtitle(width: 1728, height: 1117, hz: 120), "1728 × 1117 · 120 Hz")
        XCTAssertEqual(DisplayBlock.subtitle(width: 1920, height: 1080, hz: nil), "1920 × 1080")
    }

    func testNavigationRowValues() {
        XCTAssertEqual(NavigationRows.countText(0), "None")
        XCTAssertEqual(NavigationRows.countText(3), "3")
    }
}
