import XCTest
@testable import FBDCore

/// `.cube` 3D LUT parser tests.
///
/// A `.cube` file is user-supplied input feeding a Metal texture, so the parser
/// is asserted to be total: every malformed shape produces its specific error
/// rather than a crash or a partially-applied correction.
final class LUTCubeTests: XCTestCase {

    /// Build a valid `size³` cube body (red varying fastest) with the given RGB.
    private func body(size: Int, offset: Double = 0) -> String {
        var lines: [String] = []
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let denom = Double(size - 1)
                    lines.append("\(Double(r) / denom + offset) \(Double(g) / denom) \(Double(b) / denom)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Happy path

    func testParsesMinimalCube() throws {
        let text = "LUT_3D_SIZE 2\n" + body(size: 2)
        let lut = try LUTCubeParser.parse(text)

        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.values.count, 24)          // 2³ × 3
        XCTAssertEqual(lut.componentCount, 24)
        XCTAssertNil(lut.title)
        // Red varies fastest: entry 1 is (1,0,0).
        XCTAssertEqual(lut.values[3], 1, accuracy: 1e-6)   // R of entry 1
        XCTAssertEqual(lut.values[4], 0, accuracy: 1e-6)   // G of entry 1
        XCTAssertEqual(lut.values[5], 0, accuracy: 1e-6)   // B of entry 1
    }

    func testParsesTitleCommentsAndBlankLines() throws {
        let text = """
        # a comment
        TITLE "My Grade"

        LUT_3D_SIZE 2
        # mid-file comment

        \(body(size: 2))
        """
        let lut = try LUTCubeParser.parse(text)
        XCTAssertEqual(lut.title, "My Grade")
        XCTAssertEqual(lut.values.count, 24)
    }

    func testToleratesCRLFAndTrailingNewline() throws {
        // EOLs are composed from scalars rather than escapes: authoring tools
        // (including the one that wrote this file) can collapse an escape pair.
        let lineFeed = String(UnicodeScalar(UInt8(10)))
        let carriageReturn = String(UnicodeScalar(UInt8(13)))
        let eol = carriageReturn + lineFeed
        let text = "LUT_3D_SIZE 2" + eol
            + body(size: 2).replacingOccurrences(of: lineFeed, with: eol)
            + eol
        let lut = try LUTCubeParser.parse(text)
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.values.count, 24)
    }

    func testDomainMinMaxIsNormalised() throws {
        // Domain 0…2 with all values 2.0 must normalise to 1.0.
        var lines = ["LUT_3D_SIZE 2", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 2 2 2"]
        for _ in 0..<8 { lines.append("2 2 2") }
        let lut = try LUTCubeParser.parse(lines.joined(separator: "\n"))
        XCTAssertTrue(lut.values.allSatisfy { abs($0 - 1) < 1e-6 })
    }

    func testAcceptsUpToDeclaredMaxSize() throws {
        // 4³ keeps the fixture small while exercising a non-trivial size.
        let lut = try LUTCubeParser.parse("LUT_3D_SIZE 4\n" + body(size: 4))
        XCTAssertEqual(lut.size, 4)
        XCTAssertEqual(lut.values.count, 4 * 4 * 4 * 3)
    }

    // MARK: - Rejections

    func testRejectsOneDimensionalCube() {
        XCTAssertThrowsError(try LUTCubeParser.parse("LUT_1D_SIZE 16\n0 0 0")) { error in
            XCTAssertEqual(error as? LUTCubeError, .unsupportedDimension("LUT_1D_SIZE"))
        }
    }

    func testRejectsEmptyInput() {
        XCTAssertThrowsError(try LUTCubeParser.parse("")) { error in
            XCTAssertEqual(error as? LUTCubeError, .empty)
        }
        XCTAssertThrowsError(try LUTCubeParser.parse("\n\n# only comments\n")) { error in
            XCTAssertEqual(error as? LUTCubeError, .empty)
        }
    }

    func testRejectsMissingSizeWhenOtherDirectivesPresent() {
        XCTAssertThrowsError(try LUTCubeParser.parse("TITLE \"x\"\n0 0 0")) { error in
            XCTAssertEqual(error as? LUTCubeError, .missingSize)
        }
    }

    func testRejectsSizeBelowMinimum() {
        XCTAssertThrowsError(try LUTCubeParser.parse("LUT_3D_SIZE 1\n" + body(size: 1))) { error in
            XCTAssertEqual(error as? LUTCubeError, .invalidSize(1))
        }
    }

    func testRejectsSizeAboveMaximum() {
        XCTAssertThrowsError(try LUTCubeParser.parse("LUT_3D_SIZE 129\n" + body(size: 2))) { error in
            XCTAssertEqual(error as? LUTCubeError, .invalidSize(129))
        }
        XCTAssertThrowsError(try LUTCubeParser.parse("LUT_3D_SIZE notanumber\n")) { error in
            XCTAssertEqual(error as? LUTCubeError, .missingSize)
        }
    }

    func testRejectsWrongEntryCount() {
        // Declares 2³ = 8 entries but supplies 7.
        let short = body(size: 2).split(separator: "\n").dropLast().joined(separator: "\n")
        XCTAssertThrowsError(try LUTCubeParser.parse("LUT_3D_SIZE 2\n" + short)) { error in
            XCTAssertEqual(error as? LUTCubeError, .wrongEntryCount(expected: 8, found: 7))
        }
    }

    func testRejectsNonNumericDataRow() {
        XCTAssertThrowsError(try LUTCubeParser.parse("LUT_3D_SIZE 2\n0 0 0\n0 0 nope")) { error in
            guard case .invalidValue = (error as? LUTCubeError) else {
                return XCTFail("expected invalidValue, got \(error)")
            }
        }
    }

    func testRejectsNonFiniteComponent() {
        XCTAssertThrowsError(try LUTCubeParser.parse("LUT_3D_SIZE 2\n0 0 nan")) { error in
            guard case .invalidValue = (error as? LUTCubeError) else {
                return XCTFail("expected invalidValue, got \(error)")
            }
        }
    }

    func testRejectsZeroWidthDomain() {
        let text = "LUT_3D_SIZE 2\nDOMAIN_MIN 1 1 1\nDOMAIN_MAX 1 1 1\n" + body(size: 2)
        XCTAssertThrowsError(try LUTCubeParser.parse(text)) { error in
            guard case .invalidDomain = (error as? LUTCubeError) else {
                return XCTFail("expected invalidDomain, got \(error)")
            }
        }
    }

    func testRejectsMalformedDomainLine() {
        XCTAssertThrowsError(try LUTCubeParser.parse("LUT_3D_SIZE 2\nDOMAIN_MIN 0 0\n" + body(size: 2))) { error in
            guard case .invalidDomain = (error as? LUTCubeError) else {
                return XCTFail("expected invalidDomain, got \(error)")
            }
        }
    }

    func testRejectsNonUTF8Data() {
        let data = Data([0xFF, 0xFE, 0x00, 0x41])
        XCTAssertThrowsError(try LUTCubeParser.parse(data)) { error in
            XCTAssertEqual(error as? LUTCubeError, .notUTF8)
        }
    }

    func testRejectsOversizedDataBeforeParsing() {
        // The size guard must fire before any float parsing: this payload is
        // whitespace-only, so without the guard it would report `.empty`.
        let data = Data(repeating: 0x20, count: LUTCubeParser.maxBytes + 1)
        XCTAssertThrowsError(try LUTCubeParser.parse(data)) { error in
            XCTAssertEqual(error as? LUTCubeError, .tooLarge(bytes: data.count, limit: LUTCubeParser.maxBytes))
        }
    }

    func testMissingFileIsReportedAsUnreadable() {
        let url = URL(fileURLWithPath: "/nonexistent/fbd-does-not-exist.cube")
        XCTAssertThrowsError(try LUTCubeParser.parse(contentsOf: url)) { error in
            guard case .unreadable = (error as? LUTCubeError) else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }
}
