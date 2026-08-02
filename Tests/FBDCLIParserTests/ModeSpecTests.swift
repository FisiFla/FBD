import XCTest
@testable import FBDCLIParser

/// Tests for the `WxH[@Hz]` mode-spec parser used by `set-mode` and
/// `virtual create`.
final class ModeSpecTests: XCTestCase {
    // MARK: - Valid specs

    func testValidWithoutRefreshRate() {
        XCTAssertEqual(ModeSpec.parse("1920x1080"), ModeSpec(width: 1920, height: 1080, hz: nil))
    }

    func testValidWithRefreshRate() {
        XCTAssertEqual(ModeSpec.parse("2560x1440@120"), ModeSpec(width: 2560, height: 1440, hz: 120))
    }

    func testValidFractionalRefreshRate() {
        XCTAssertEqual(ModeSpec.parse("1920x1080@59.94"), ModeSpec(width: 1920, height: 1080, hz: 59.94))
    }

    func testValidSingleDigitDimensions() {
        XCTAssertEqual(ModeSpec.parse("1x1@1"), ModeSpec(width: 1, height: 1, hz: 1))
    }

    // MARK: - Invalid specs

    private func assertInvalid(_ spec: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(ModeSpec.parse(spec), "expected '\(spec)' to be rejected", file: file, line: line)
    }

    func testEmptyAndGarbageSpecsAreRejected() {
        assertInvalid("")
        assertInvalid("x")
        assertInvalid("1920")
        assertInvalid("1920x")
        assertInvalid("x1080")
        assertInvalid("abcxdef")
        assertInvalid(" 1920x1080")
        assertInvalid("1920x1080 ")
    }

    func testNonPositiveDimensionsAreRejected() {
        assertInvalid("0x1080")
        assertInvalid("1920x0")
        assertInvalid("-1x1080")
        assertInvalid("1920x-1")
    }

    func testBadRefreshRatesAreRejected() {
        assertInvalid("1920x1080@0")
        assertInvalid("1920x1080@-60")
        assertInvalid("1920x1080@abc")
        assertInvalid("1920x1080@")
        assertInvalid("1920x1080@60@30")
    }

    func testUppercaseXIsRejected() {
        // The spec grammar is lowercase 'x' (documented in help text).
        assertInvalid("1920X1080")
    }

    func testIntegerOverflowIsRejected() {
        assertInvalid("99999999999999999999x1080")
    }

    // MARK: - Round-trip with the formatter

    func testSpecRoundTripsThroughFormatterShape() {
        let spec = ModeSpec.parse("3840x2160@60")!
        let formatted = String(format: "%ux%u@%g", spec.width, spec.height, spec.hz ?? 60)
        XCTAssertEqual(ModeSpec.parse(formatted), spec)
    }
}
