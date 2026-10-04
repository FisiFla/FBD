import XCTest
@testable import FBDCore

/// Parsing the DDC VCP 0x60 value list out of a display's capabilities reply,
/// and naming the values.
///
/// This is what lets the DDC panel offer "HDMI 1 / HDMI 2 / DisplayPort 1" from
/// the values a display reports, instead of asking the user for a raw VCP number
/// — or, worse, showing a fixed standard list that may not match the display's
/// own numbering.
final class DDCInputSourceTests: XCTestCase {

    // MARK: - capabilityValues

    func testParsesAValueList() {
        // The real grammar: the code, then its values in single-level parens.
        let text = "vcp(10 12 60(0F 10 11 12))mccs_ver(2.2)"
        XCTAssertEqual(DDC.capabilityValues(for: 0x60, in: text), [0x0F, 0x10, 0x11, 0x12])
    }

    func testPreservesTheDisplaysOwnOrder() {
        // Not sorted — the display's order is meaningful information (it is often
        // physical port order), so it is passed through untouched.
        XCTAssertEqual(DDC.capabilityValues(for: 0x60, in: "vcp(60(12 0F 11))"), [0x12, 0x0F, 0x11])
    }

    func testDropsDuplicates() {
        XCTAssertEqual(DDC.capabilityValues(for: 0x60, in: "vcp(60(0F 0F 10))"), [0x0F, 0x10])
    }

    func testACodeWithoutAValueSetYieldsNothing() {
        // Very common: the display lists 0x60 as supported but not which inputs.
        // The caller must fall back to the raw field rather than invent a list.
        XCTAssertEqual(DDC.capabilityValues(for: 0x60, in: "vcp(10 12 60 62)"), [])
    }

    func testDoesNotMatchTheCodeInsideALongerToken() {
        // `160(` must not be read as code 0x60 — a naive substring match would.
        XCTAssertEqual(DDC.capabilityValues(for: 0x60, in: "vcp(160(01 02))"), [])
    }

    func testIsCaseInsensitiveOnTheCode() {
        XCTAssertEqual(DDC.capabilityValues(for: 0x60, in: "vcp(60(0f 10))"), [0x0F, 0x10])
    }

    func testOtherCodesAreLeftAlone() {
        XCTAssertEqual(DDC.capabilityValues(for: 0x10, in: "vcp(10 12 60(0F 10))"), [])
    }

    func testGarbageInputIsEmptyNotACrash() {
        for text in ["", "not capabilities at all", "vcp(", "vcp(60(", "vcp(60())"] {
            XCTAssertEqual(DDC.capabilityValues(for: 0x60, in: text), [], "input: \(text)")
        }
    }

    // MARK: - inputSourceName

    func testNamesTheStandardValues() {
        XCTAssertEqual(DDC.inputSourceName(for: 0x0F), "DisplayPort 1")
        XCTAssertEqual(DDC.inputSourceName(for: 0x11), "HDMI 1")
        XCTAssertEqual(DDC.inputSourceName(for: 0x01), "Analog 1")
    }

    func testUnnamedValuesReturnNilSoTheCallerCanShowTheNumber() {
        // Silently inventing a name for an unknown value would be the same class
        // of bug as the wrong-list problem this whole path avoids.
        XCTAssertNil(DDC.inputSourceName(for: 0x7F))
        XCTAssertNil(DDC.inputSourceName(for: 0x00))
    }

    // MARK: - Round trip through the real parser

    func testWorksOnValuesASubjectThatWentThroughParseCapabilities() {
        let capabilities = DDC.parseCapabilities("vcp(10 12 60(0F 10 11 12))mccs_ver(2.2)")
        XCTAssertTrue(capabilities.supports(0x60))
        XCTAssertEqual(
            DDC.capabilityValues(for: 0x60, in: capabilities.raw),
            [0x0F, 0x10, 0x11, 0x12]
        )
    }
}
