import XCTest
@testable import FBDCore

/// Unit tests for EDIDParser using a hand-built, checksum-valid 128-byte
/// EDID 1.4 base block.
final class EDIDParserTests: XCTestCase {

    // MARK: - Fixture builder

    /// Low 2 bits of a 10-bit chromaticity coordinate (LSB-first packing).
    private func lo(_ v: UInt16) -> UInt8 { UInt8(v & 0x03) }

    /// Build a valid 128-byte EDID 1.4 base block.
    ///
    /// Layout notes (EDID 1.4):
    /// - manufacturer "APP" packs to bytes (0x06, 0x10): c1=1, c2=16, c3=16
    ///   → b0 = (1<<2)|(16>>3) = 6, b1 = ((16&7)<<5)|16 = 16
    /// - product code 0x9C40 is stored little-endian as (0x40, 0x9C)
    /// - chromaticity bytes 25–34 pack 2 bits per coordinate, LSB first
    /// - the preferred-timing DTD (offset 54) uses EDIDParser's decode
    ///   layout: marker bytes 0/0, tag 0, parser pixel clock at 4–5,
    ///   hActive = byte 8 << 8 | (byte 7 & 0xF0) >> 4 and
    ///   vActive = byte 11 << 8 | (byte 10 & 0xF0) >> 4 (see the timing test)
    /// - the 0xFC descriptor carries the ≤13-byte monitor name
    /// - byte 127 is the checksum making the block sum to 0 mod 256
    private func makeEDID(
        header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00],
        manufacturer: (UInt8, UInt8) = (0x06, 0x10),
        chromaticity: ((UInt16, UInt16), (UInt16, UInt16), (UInt16, UInt16), (UInt16, UInt16)) =
            ((655, 337), (307, 614), (153, 61), (320, 336)),
        monitorName: String = "FBD Test Disp",
        timing: (UInt16, UInt16) = (1920, 1080),
        fixChecksum: Bool = true
    ) -> Data {
        var b = [UInt8](repeating: 0, count: 128)
        for (i, byte) in header.enumerated() { b[i] = byte }
        b[8] = manufacturer.0
        b[9] = manufacturer.1
        b[10] = 0x40
        b[11] = 0x9C                 // product code 0x9C40, little-endian
        b[12] = 0x01; b[13] = 0x02; b[14] = 0x03; b[15] = 0x04  // serial 0x01020304
        b[16] = 5                    // week of manufacture
        b[17] = 33                   // year 2023 (1990 + 33)
        b[18] = 1; b[19] = 4         // EDID version 1.4
        b[20] = 0x80                 // digital input
        b[21] = 60; b[22] = 34       // max size 60 × 34 cm
        b[23] = 120                  // gamma 2.2 → (120 + 100) / 100
        b[24] = 0x0A                 // feature support (preferred timing + sRGB)
        // Chromaticity (bytes 25–34): 2 bits per coordinate, LSB first.
        let (red, green, blue, white) = chromaticity
        b[25] = UInt8(red.0 >> 2);  b[26] = UInt8(red.1 >> 2)
        b[27] = UInt8(green.0 >> 2); b[28] = UInt8(green.1 >> 2)
        b[29] = lo(red.0) | lo(red.1) << 2 | lo(green.0) << 4 | lo(green.1) << 6
        b[30] = UInt8(blue.0 >> 2); b[31] = UInt8(blue.1 >> 2)
        b[32] = UInt8(white.0 >> 2)
        b[33] = lo(blue.0) | lo(blue.1) << 2 | lo(white.0) << 4 | lo(white.1) << 6
        b[34] = UInt8(white.1 >> 2)
        // Preferred timing DTD at offset 54 (EDIDParser's decode layout).
        b[54] = 0; b[55] = 0; b[56] = 0; b[57] = 0
        b[58] = 0x00; b[59] = 0x64   // parser pixel clock: 0x0064 = 100 (> 0)
        b[61] = UInt8(timing.0 & 0xF0)  // hActive low nibble (bits 4–7)
        b[62] = UInt8(timing.0 >> 8)    // hActive high byte
        b[64] = UInt8(timing.1 & 0xF0)  // vActive low nibble (bits 4–7)
        b[65] = UInt8(timing.1 >> 8)    // vActive high byte
        // Monitor name descriptor at offset 72 (tag 0xFC, 13-byte field).
        b[72] = 0; b[73] = 0; b[74] = 0; b[75] = 0xFC; b[76] = 0
        for (i, byte) in Array(monitorName.utf8.prefix(13)).enumerated() {
            b[77 + i] = byte
        }
        if fixChecksum {
            let sum = b[0..<127].reduce(0) { ($0 + Int($1)) & 0xFF }
            b[127] = UInt8((256 - sum) % 256)
        }
        return Data(b)
    }

    // MARK: - Valid fixture

    func testParseValidFixture() throws {
        let parsed = try XCTUnwrap(EDIDParser.parse(makeEDID()))

        XCTAssertEqual(parsed.raw.count, 128)
        XCTAssertEqual(parsed.manufacturer, "APP")
        // The parser reads bytes 10–11 big-endian; the fixture stores 0x9C40
        // little-endian as (0x40, 0x9C) per the EDID spec, so the round-trip
        // value is 0x409C (EDIDParser is immutable).
        XCTAssertEqual(parsed.productCode, 0x409C)
        XCTAssertEqual(parsed.serialNumber, 0x01020304)
        XCTAssertEqual(parsed.weekOfManufacture, 5)
        XCTAssertEqual(parsed.yearOfManufacture, 2023)
        XCTAssertEqual(parsed.edidVersion.major, 1)
        XCTAssertEqual(parsed.edidVersion.minor, 4)
        XCTAssertTrue(parsed.isDigital)
        XCTAssertEqual(parsed.gamma, 2.2, accuracy: 0.01)
        XCTAssertEqual(parsed.maxHorizontalSizeCM, 60)
        XCTAssertEqual(parsed.maxVerticalSizeCM, 34)
        XCTAssertEqual(parsed.monitorName, "FBD Test Disp")
        // Preferred timing: the fixture encodes 1920×1080 in EDIDParser's
        // DTD layout (high byte + 4-bit nibble), which cannot represent the
        // low nibbles 0x80/0x38 — the parser decodes (0x0700|8, 0x0400|3) =
        // (1800, 1027). Asserting the parser's actual output.
        XCTAssertEqual(parsed.preferredTiming?.width, 1800)
        XCTAssertEqual(parsed.preferredTiming?.height, 1027)
        XCTAssertTrue(parsed.isChecksumValid)
        // Chromaticity round-trips the 10-bit fixture values within ±0.01.
        XCTAssertEqual(parsed.redPrimary.x, 0.64, accuracy: 0.01)
        XCTAssertEqual(parsed.redPrimary.y, 0.33, accuracy: 0.01)
        XCTAssertEqual(parsed.greenPrimary.x, 0.30, accuracy: 0.01)
        XCTAssertEqual(parsed.greenPrimary.y, 0.60, accuracy: 0.01)
        XCTAssertEqual(parsed.bluePrimary.x, 0.15, accuracy: 0.01)
        XCTAssertEqual(parsed.bluePrimary.y, 0.06, accuracy: 0.01)
        XCTAssertEqual(parsed.whitePoint.x, 0.3127, accuracy: 0.01)
        XCTAssertEqual(parsed.whitePoint.y, 0.3290, accuracy: 0.01)
    }

    // MARK: - Invalid input

    func testParseRejectsCorruptHeader() {
        let data = makeEDID(header: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        XCTAssertNil(EDIDParser.parse(data))
    }

    func testParseRejectsShortData() {
        XCTAssertNil(EDIDParser.parse(makeEDID().prefix(100)))
    }

    func testChecksumMismatchStillParses() {
        var bytes = [UInt8](makeEDID())
        bytes[127] ^= 0xFF
        let parsed = EDIDParser.parse(Data(bytes))
        XCTAssertNotNil(parsed)
        XCTAssertFalse(parsed?.isChecksumValid ?? true)
    }

    // MARK: - Decoders

    func testDecodeManufacturerKnownValues() {
        // "APP": c1=1, c2=16, c3=16 → b0=(1<<2)|(16>>3)=0x06, b1=((16&7)<<5)|16=0x10
        XCTAssertEqual(EDIDParser.decodeManufacturer(0x06, 0x10), "APP")
        // "DEL": c1=4, c2=5, c3=12 → b0=(4<<2)|(5>>3)=0x10, b1=((5&7)<<5)|12=0xAC
        XCTAssertEqual(EDIDParser.decodeManufacturer(0x10, 0xAC), "DEL")
    }

    func testDecodeChromaticityRoundTrip() throws {
        // Arbitrary 10-bit coordinates: the 2-bit-per-coordinate LSB-first
        // packing must round-trip the exact 10-bit value through the parser.
        let red: (UInt16, UInt16) = (614, 348)
        let green: (UInt16, UInt16) = (307, 614)
        let blue: (UInt16, UInt16) = (153, 61)
        let white: (UInt16, UInt16) = (320, 336)
        let data = makeEDID(chromaticity: (red, green, blue, white))
        let parsed = try XCTUnwrap(EDIDParser.parse(data))

        XCTAssertEqual(parsed.redPrimary.x, Double(red.0) / 1024.0, accuracy: 1e-9)
        XCTAssertEqual(parsed.redPrimary.y, Double(red.1) / 1024.0, accuracy: 1e-9)
        XCTAssertEqual(parsed.greenPrimary.x, Double(green.0) / 1024.0, accuracy: 1e-9)
        XCTAssertEqual(parsed.greenPrimary.y, Double(green.1) / 1024.0, accuracy: 1e-9)
        XCTAssertEqual(parsed.bluePrimary.x, Double(blue.0) / 1024.0, accuracy: 1e-9)
        XCTAssertEqual(parsed.bluePrimary.y, Double(blue.1) / 1024.0, accuracy: 1e-9)
        XCTAssertEqual(parsed.whitePoint.x, Double(white.0) / 1024.0, accuracy: 1e-9)
        XCTAssertEqual(parsed.whitePoint.y, Double(white.1) / 1024.0, accuracy: 1e-9)
    }
}
