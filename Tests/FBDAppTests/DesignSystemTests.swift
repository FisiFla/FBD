@testable import FBD
import SwiftUI
import XCTest

final class DesignSystemTests: XCTestCase {
    func testToggleTileStateText() {
        XCTAssertEqual(FBDToggleTile.stateText(isOn: true, isEnabled: true), "On")
        XCTAssertEqual(FBDToggleTile.stateText(isOn: false, isEnabled: true), "Off")
        XCTAssertEqual(FBDToggleTile.stateText(isOn: false, isEnabled: false), "Unavailable")
    }

    func testSliderValueOverlayOnlyWhileDragging() {
        XCTAssertFalse(FDBSlider.showsValueOverlay(isDragging: false))
        XCTAssertTrue(FDBSlider.showsValueOverlay(isDragging: true))
    }
}
