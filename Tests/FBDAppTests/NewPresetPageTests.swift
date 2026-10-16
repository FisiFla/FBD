@testable import FBD
import FBDCore
import XCTest

final class NewPresetPageTests: XCTestCase {
    func testNameValidation() {
        XCTAssertNil(NewPresetPage.validatedName("   "))
        XCTAssertEqual(NewPresetPage.validatedName("  Movie  "), "Movie")
        let long = String(repeating: "x", count: DisplayPreset.maximumNameLength + 5)
        XCTAssertEqual(NewPresetPage.validatedName(long)?.count, DisplayPreset.maximumNameLength)
    }
}
