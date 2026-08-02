import XCTest
@testable import FBDCLIParser

/// Tests for the EDID hex helpers (`edid apply` input, `edid export` dump).
final class EDIDHexTests: XCTestCase {
    // MARK: - parse

    func testParsesPlainHex() {
        XCTAssertEqual(EDIDHex.parse("00FF10"), Data([0x00, 0xFF, 0x10]))
    }

    func testParsesLowercaseAndWhitespace() {
        XCTAssertEqual(EDIDHex.parse("00 ff ff\nff ff 00"), Data([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]))
    }

    func testRejectsOddLength() {
        XCTAssertNil(EDIDHex.parse("0FF"))
        XCTAssertNil(EDIDHex.parse("0"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(EDIDHex.parse(""))
        XCTAssertNil(EDIDHex.parse("   "))
    }

    func testRejectsNonHex() {
        XCTAssertNil(EDIDHex.parse("00ZZ"))
        XCTAssertNil(EDIDHex.parse("00G1"))
    }

    func testRoundTripThroughDump() {
        // A dump line parses back to the same bytes (spaces tolerated).
        let data = Data([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01, 0x02, 0x03])
        let dump = EDIDHex.dump(data)
        let lines = dump.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let hex = String(lines[0].split(separator: ": ")[1])
        XCTAssertEqual(EDIDHex.parse(hex), data)
    }

    // MARK: - dump

    func testDumpFormatting() {
        let dump = EDIDHex.dump(Data([0x00, 0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(dump, "0000: 00 01 02 03 04")
    }

    func testDumpMultipleLines() {
        let data = Data((0..<20).map { UInt8($0) })
        let dump = EDIDHex.dump(data)
        let lines = dump.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("0000: "))
        XCTAssertTrue(lines[1].hasPrefix("0010: "))
    }

    func testDumpEmpty() {
        XCTAssertEqual(EDIDHex.dump(Data()), "")
    }
}
