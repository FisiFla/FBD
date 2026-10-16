@testable import FBD
import XCTest

final class PanelSizingTests: XCTestCase {
    func testPanelHeightIsCappedToScreen() {
        XCTAssertEqual(PanelSizing.height(content: 400, screenVisibleHeight: 1000), 400)
        XCTAssertEqual(PanelSizing.height(content: 2000, screenVisibleHeight: 1000), 850)
        XCTAssertEqual(PanelSizing.height(content: 0, screenVisibleHeight: 1000), PanelSizing.minimumHeight)
    }
}
