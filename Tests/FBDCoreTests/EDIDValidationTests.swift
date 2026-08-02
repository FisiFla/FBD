import XCTest
import FBDCore

/// Structural validation tests for EDID overrides (size, header, checksum).
final class EDIDValidationTests: XCTestCase {
    /// Build a structurally valid EDID: header, zeroed payload, extension
    /// count byte, and a correct checksum on every 128-byte block.
    private func makeEDID(blocks: Int, mutate: ((inout [UInt8]) -> Void)? = nil) -> Data {
        var bytes = [UInt8](repeating: 0, count: blocks * 128)
        bytes[0...7] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        bytes[126] = UInt8(blocks - 1) // extension block count
        for block in 0..<blocks {
            let start = block * 128
            let sum = bytes[start..<(start + 127)].reduce(0) { ($0 + Int($1)) & 0xFF }
            bytes[start + 127] = UInt8((0x100 - sum) & 0xFF)
        }
        mutate?(&bytes)
        return Data(bytes)
    }

    // MARK: - Valid EDIDs

    func testValidBaseBlockPasses() {
        XCTAssertNil(EDIDValidation.validate(makeEDID(blocks: 1)))
        XCTAssertTrue(EDIDValidation.isValid(makeEDID(blocks: 1)))
    }

    func testValidEDIDWithExtensionBlocksPasses() {
        XCTAssertNil(EDIDValidation.validate(makeEDID(blocks: 2)))
        XCTAssertNil(EDIDValidation.validate(makeEDID(blocks: 4))) // 512 = max
    }

    // MARK: - Size rules

    func testTooShortRejected() {
        let reason = EDIDValidation.validate(Data([0x00, 0xFF, 0xFF]))
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("128"), reason!)
    }

    func test127BytesRejected() {
        XCTAssertNotNil(EDIDValidation.validate(makeEDID(blocks: 1).dropLast()))
    }

    func testNonMultipleOf128Rejected() {
        XCTAssertNotNil(EDIDValidation.validate(makeEDID(blocks: 1) + Data([0x00]))) // 129
        XCTAssertNotNil(EDIDValidation.validate(makeEDID(blocks: 1) + Data([0x00, 0x00]))) // 130
    }

    func testOver512BytesRejected() {
        XCTAssertNotNil(EDIDValidation.validate(makeEDID(blocks: 5)))
    }

    func testEmptyRejected() {
        XCTAssertNotNil(EDIDValidation.validate(Data()))
    }

    // MARK: - Header / checksum

    func testBadHeaderRejected() {
        let edid = makeEDID(blocks: 1) { bytes in bytes[0] = 0x01 }
        let reason = EDIDValidation.validate(edid)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("header"), reason!)
    }

    func testBadChecksumRejected() {
        let edid = makeEDID(blocks: 1) { bytes in bytes[100] &+= 1 }
        let reason = EDIDValidation.validate(edid)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("checksum"), reason!)
    }

    // MARK: - Round-trip through the persistence gate

    func testSaveOverrideRejectsInvalidEDID() {
        let controller = EDIDController()
        // Random serial keeps the identity key unique per test run.
        let display = Display(
            id: 0x9999,
            name: "Test",
            isBuiltin: false,
            vendorNumber: 0x1234,
            modelNumber: 0x5678,
            serialNumber: UInt32.random(in: 1...UInt32.max),
            bounds: .zero,
            isOnline: true,
            isActive: true
        )
        let identity = display.identityKey
        defer { Settings.setEDIDOverride(nil, for: identity) }

        controller.saveOverride(Data([0x00, 0x01, 0x02]), for: display)
        XCTAssertNil(Settings.edidOverride(for: identity), "garbage must not be persisted")

        let valid = makeEDID(blocks: 1)
        controller.saveOverride(valid, for: display)
        XCTAssertEqual(Settings.edidOverride(for: identity), valid)

        controller.saveOverride(nil, for: display)
        XCTAssertNil(Settings.edidOverride(for: identity), "nil must clear the override")
    }
}
