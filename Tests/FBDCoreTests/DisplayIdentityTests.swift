import XCTest
@testable import FBDCore

/// Row #28, the identity half: how a display is matched to its stored settings.
final class DisplayIdentityTests: XCTestCase {
    private let vendor: UInt32 = 1552
    private let model: UInt32 = 41040
    private let serial: UInt32 = 1234567

    private func key(_ name: String, _ method: DisplayIdentityMethod) -> String {
        DisplayIdentity.key(vendor: vendor, model: model, serial: serial, name: name, method: method)
    }

    // MARK: - The default must not move anything

    /// The load-bearing assertion of this row: if the default key's shape ever
    /// changes, every existing per-display setting is silently orphaned.
    func testDefaultReproducesTheHistoricalKeyExactly() {
        XCTAssertEqual(key("Studio Display", .vendorModelSerial), "1552-41040-1234567")
        XCTAssertEqual(DisplayIdentityMethod.default, .vendorModelSerial)
    }

    func testEachMethodProducesItsDocumentedKey() {
        XCTAssertEqual(key("OLED TV", .vendorModel), "1552-41040")
        XCTAssertEqual(key("OLED TV", .serial), "1234567")
        XCTAssertEqual(key("OLED TV", .displayName), "oled tv")
    }

    func testEveryMethodProducesADistinctKeyForTheSameDisplay() {
        let keys = DisplayIdentityMethod.allCases.map { key("Panel", $0) }
        XCTAssertEqual(
            Set(keys).count, DisplayIdentityMethod.allCases.count,
            "two methods collide, so switching would not re-key"
        )
    }

    // MARK: - Name normalisation

    func testNameMethodIgnoresCaseAndWhitespaceRuns() {
        XCTAssertEqual(
            key("  Studio   Display ", .displayName),
            key("studio display", .displayName)
        )
    }

    /// Two nameless displays would otherwise share one empty identity and
    /// silently share every setting.
    func testANamelessDisplayFallsBackToThePreciseKey() {
        for blank in ["", "   ", "\n\t "] {
            XCTAssertEqual(key(blank, .displayName), "1552-41040-1234567")
        }
    }

    // MARK: - Degradation

    func testAnUnrecognisedStoredMethodDegradesToTheDefault() {
        XCTAssertNil(DisplayIdentityMethod(rawValue: "byVibes"))
        XCTAssertEqual(DisplayIdentityMethod(rawValue: "byVibes") ?? .default, .vendorModelSerial)
    }

    func testEveryMethodHasALabelAndACaveat() {
        for method in DisplayIdentityMethod.allCases {
            XCTAssertFalse(method.label.isEmpty, "\(method.rawValue) has no label")
            XCTAssertFalse(method.caveat.isEmpty, "\(method.rawValue) does not say what it costs")
        }
    }

    func testTheDefaultIsOfferedInTheCaseList() {
        XCTAssertTrue(DisplayIdentityMethod.allCases.contains(.default))
    }
}
