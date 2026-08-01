import Foundation

/// Pure EDID (Extended Display Identification Data) parser — EDID 1.4 base
/// block (128 bytes). Unit-tested; no I/O, no private APIs.
public enum EDIDParser {
    /// Parsed summary of a 128-byte EDID base block.
    public struct ParsedEDID: Sendable {
        public let raw: Data
        public let manufacturer: String      // 3-letter PNP ID (e.g. "APP")
        public let productCode: UInt16
        public let serialNumber: UInt32
        public let weekOfManufacture: UInt8
        public let yearOfManufacture: Int
        public let edidVersion: (major: UInt8, minor: UInt8)
        public let isDigital: Bool
        public let gamma: Double             // 2.2 → 2.2 (0 when unspecified)
        public let maxHorizontalSizeCM: UInt8
        public let maxVerticalSizeCM: UInt8
        public let redPrimary: (x: Double, y: Double)
        public let greenPrimary: (x: Double, y: Double)
        public let bluePrimary: (x: Double, y: Double)
        public let whitePoint: (x: Double, y: Double)
        public let monitorName: String?
        public let preferredTiming: (width: UInt16, height: UInt16)?  // from preferred detailed timing descriptor
        public let isChecksumValid: Bool
    }

    /// Parse a base EDID block. Returns nil when the header signature is wrong
    /// or the block is too short.
    public static func parse(_ data: Data) -> ParsedEDID? {
        let bytes = [UInt8](data)
        guard bytes.count >= 128 else { return nil }
        // Header: 00 FF FF FF FF FF FF 00
        guard bytes[0] == 0x00, bytes[1] == 0xFF, bytes[2] == 0xFF, bytes[3] == 0xFF,
              bytes[4] == 0xFF, bytes[5] == 0xFF, bytes[6] == 0xFF, bytes[7] == 0x00 else {
            return nil
        }

        let manufacturer = decodeManufacturer(bytes[8], bytes[9])
        let productCode = UInt16(bytes[10]) << 8 | UInt16(bytes[11])
        let serialNumber = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16
            | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
        let week = bytes[16]
        let year = 1990 + Int(bytes[17])
        let version = (major: bytes[18], minor: bytes[19])
        let isDigital = bytes[20] & 0x80 != 0
        let gamma = bytes[23] == 0xFF ? 0.0 : (Double(bytes[23]) + 100) / 100.0
        let maxH = bytes[21]
        let maxV = bytes[22]

        // Chromaticity (bytes 25–34): 2-bit × 6 channels packed.
        let (red, green, blue, white) = decodeChromaticity(bytes)

        var monitorName: String?
        var preferredTiming: (UInt16, UInt16)?
        // Detailed timing descriptors start at byte 54; the preferred timing is
        // the first non-zero descriptor; the monitor name is the ASCII descriptor.
        for offset in stride(from: 54, to: 126, by: 18) {
            let tag = bytes[offset + 3]
            if tag == 0xFC {
                // Monitor name descriptor
                var nameBytes = Array(bytes[(offset + 5)..<(offset + 18)])
                while nameBytes.last == 0x0A || nameBytes.last == 0x20 {
                    nameBytes.removeLast()
                }
                let name = String(decoding: nameBytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { monitorName = name }
            } else if preferredTiming == nil, tag == 0x00, bytes[offset] == 0x00, bytes[offset + 1] == 0x00 {
                // DTD header 00 00 00 tag — preferred timing (tag 0x00 + pixel clock > 0)
                let pixelClock = UInt16(bytes[offset + 4]) << 8 | UInt16(bytes[offset + 5])
                if pixelClock > 0 {
                    let hActive = UInt16(bytes[offset + 8]) << 8 | UInt16(bytes[offset + 7] & 0xF0) >> 4
                    let hBlank = UInt16(bytes[offset + 9]) << 8 | UInt16(bytes[offset + 7] & 0x0F) << 4
                    let vActive = UInt16(bytes[offset + 11]) << 8 | UInt16(bytes[offset + 10] & 0xF0) >> 4
                    let vBlank = UInt16(bytes[offset + 12]) << 8 | UInt16(bytes[offset + 10] & 0x0F) << 4
                    let hTotal = hActive + hBlank
                    let vTotal = vActive + vBlank
                    if hTotal > 0, vTotal > 0 {
                        preferredTiming = (hActive, vActive)
                    }
                }
            }
        }

        // Spec: the last byte makes the sum of all 128 bytes ≡ 0 (mod 256).
        let checksum = bytes[0..<127].reduce(0) { ($0 + Int($1)) & 0xFF }
        let isChecksumValid = (checksum + Int(bytes[127])) & 0xFF == 0

        return ParsedEDID(
            raw: Data(bytes.prefix(128)),
            manufacturer: manufacturer,
            productCode: productCode,
            serialNumber: serialNumber,
            weekOfManufacture: week,
            yearOfManufacture: year,
            edidVersion: version,
            isDigital: isDigital,
            gamma: gamma,
            maxHorizontalSizeCM: maxH,
            maxVerticalSizeCM: maxV,
            redPrimary: red,
            greenPrimary: green,
            bluePrimary: blue,
            whitePoint: white,
            monitorName: monitorName,
            preferredTiming: preferredTiming,
            isChecksumValid: isChecksumValid
        )
    }

    /// 3-letter PNP manufacturer ID from the packed 5-bit-per-letter encoding.
    static func decodeManufacturer(_ b0: UInt8, _ b1: UInt8) -> String {
        let c1 = (b0 >> 2) & 0x1F
        let c2 = ((b0 & 0x03) << 3) | ((b1 >> 5) & 0x07)
        let c3 = b1 & 0x1F
        func letter(_ v: UInt8) -> String {
            v == 0 ? "" : String(UnicodeScalar(0x40 + v))
        }
        return letter(c1) + letter(c2) + letter(c3)
    }

    /// EDID chromaticity bit-packing: 2 bits per coordinate, 6 channels, LSB first.
    static func decodeChromaticity(_ b: [UInt8]) -> ((Double, Double), (Double, Double), (Double, Double), (Double, Double)) {
        func coord(_ hi: UInt8, _ lo: UInt8) -> Double {
            Double((Int(hi) << 2) | Int(lo)) / 1024.0
        }
        let redX = coord(b[25], b[29] & 0x03)
        let redY = coord(b[26], (b[29] >> 2) & 0x03)
        let greenX = coord(b[27], (b[29] >> 4) & 0x03)
        let greenY = coord(b[28], (b[29] >> 6) & 0x03)
        let blueX = coord(b[30], b[33] & 0x03)
        let blueY = coord(b[31], (b[33] >> 2) & 0x03)
        let whiteX = coord(b[32], (b[33] >> 4) & 0x03)
        let whiteY = coord(b[34], (b[33] >> 6) & 0x03)
        return ((redX, redY), (greenX, greenY), (blueX, blueY), (whiteX, whiteY))
    }
}
