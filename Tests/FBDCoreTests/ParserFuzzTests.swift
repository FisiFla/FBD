import XCTest
import FBDCore

/// Crash-safety fuzz for the pure parsers (EDID, DDC wire format). Parsers
/// are the classic crash surface on malformed input; these deterministic
/// seeded sweeps assert they never crash and never hang.
final class ParserFuzzTests: XCTestCase {
    /// Deterministic SplitMix64 (same seed scheme as the HTTPServer fuzz).
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func randomBlob(_ rng: inout SplitMix64, maxLength: Int) -> Data {
        let length = Int(rng.next() % UInt64(maxLength))
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        for _ in 0..<length { bytes.append(UInt8(truncatingIfNeeded: rng.next())) }
        return Data(bytes)
    }

    func testEDIDParserSurvivesRandomBlobs() {
        var rng = SplitMix64(seed: 0xED1D_ED1D)
        for _ in 0..<300 {
            var blob = randomBlob(&rng, maxLength: 600)
            // Half the blobs start with a valid header so the parser goes
            // deep into field extraction instead of bailing at the gate.
            if Int(rng.next() % 2) == 0, blob.count >= 8 {
                blob[0...7] = Data([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
            }
            // Must never crash; nil is a fine outcome.
            _ = EDIDParser.parse(blob)
        }
    }

    func testVCPReplyParserSurvivesRandomBlobs() {
        var rng = SplitMix64(seed: 0xDC00_DC00)
        for _ in 0..<300 {
            let blob = randomBlob(&rng, maxLength: 16)
            _ = DDC.parseVCPReply(blob)
        }
    }

    func testCapabilitiesTextParserSurvivesRandomBlobs() {
        var rng = SplitMix64(seed: 0xC4A5_C4A5)
        for _ in 0..<300 {
            let blob = randomBlob(&rng, maxLength: 300)
            _ = DDC.parseCapabilitiesText(blob)
        }
    }

    func testCapabilitiesParserSurvivesRandomStrings() {
        var rng = SplitMix64(seed: 0x5EED_5EED)
        let alphabet = Array("vcp()Fmccs_ver0123456789ABCDEFabcdef \r\n\t.\\\"".utf8)
        for _ in 0..<300 {
            let length = Int(rng.next() % 120)
            var bytes = [UInt8]()
            for _ in 0..<length { bytes.append(alphabet[Int(rng.next() % UInt64(alphabet.count))]) }
            let text = String(decoding: bytes, as: UTF8.self)
            _ = DDC.parseCapabilities(text)
        }
    }
}
