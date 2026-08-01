import XCTest
@testable import FBDCore

final class DDCProtocolTests: XCTestCase {
    // MARK: - VCP write packet

    func testWriteVCPPacketBuildsSetFeaturePacket() {
        // Arrange
        let code: UInt8 = 0x10

        // Act
        let packet = DDC.writeVCPPacket(code: code, value: 100)

        // Assert: [source, 0x6C, code, hi, lo, checksum]
        XCTAssertEqual(packet, [0x51, 0x6C, 0x10, 0x00, 0x64, 0xCF])
    }

    func testWriteVCPPacketEncodesValueBigEndianAcrossTwoBytes() {
        // Arrange
        let code: UInt8 = 0x10

        // Act
        let packet = DDC.writeVCPPacket(code: code, value: 0x1234)

        // Assert
        XCTAssertEqual(packet, [0x51, 0x6C, 0x10, 0x12, 0x34, 0xED])
    }

    // MARK: - VCP read request

    func testReadVCPRequestBuildsGetFeaturePacket() {
        // Act
        let request = DDC.readVCPRequest(code: 0x10)

        // Assert: [source, 0x6D, code, checksum] — 0x51 + 0x6D + 0x10 = 0xCE → checksum 0x32
        XCTAssertEqual(request, [0x51, 0x6D, 0x10, 0x32])
    }

    // MARK: - VCP reply parsing

    func testParseVCPReplyExtractsCodeAndValues() {
        // Arrange
        let reply = Data([0x6E, 0x10, 0x03, 0x00, 0x64, 0x00, 0x32, 0x6F])

        // Act
        let parsed = DDC.parseVCPReply(reply)

        // Assert
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.code, 0x10)
        XCTAssertEqual(parsed?.value, DDC.DDCValue(maxValue: 100, currentValue: 50))
    }

    func testParseVCPReplyAcceptsValidChecksumTerminator() {
        // Arrange: last byte = checksum so byte sum ≡ 0 (mod 256)
        // 0x6E+0x10+0x03+0x00+0x64+0x00+0x32 = 0x117 → checksum = 0xE9
        let reply = Data([0x6E, 0x10, 0x03, 0x00, 0x64, 0x00, 0x32, 0xE9])

        // Act
        let parsed = DDC.parseVCPReply(reply)

        // Assert
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.code, 0x10)
        XCTAssertEqual(parsed?.value, DDC.DDCValue(maxValue: 100, currentValue: 50))
    }

    func testParseVCPReplyTolerates0x6DFirstByteEcho() {
        // Arrange
        let reply = Data([0x6D, 0x10, 0x03, 0x00, 0x64, 0x00, 0x32, 0x6F])

        // Act
        let parsed = DDC.parseVCPReply(reply)

        // Assert
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.code, 0x10)
        XCTAssertEqual(parsed?.value, DDC.DDCValue(maxValue: 100, currentValue: 50))
    }

    func testParseVCPReplyRejectsShortData() {
        // Arrange
        let reply = Data([0x6E, 0x10, 0x03, 0x00])

        // Act
        let parsed = DDC.parseVCPReply(reply)

        // Assert
        XCTAssertNil(parsed)
    }

    func testParseVCPReplyRejectsWrongTerminator() {
        // Arrange
        let reply = Data([0x6E, 0x10, 0x03, 0x00, 0x64, 0x00, 0x32, 0x00])

        // Act
        let parsed = DDC.parseVCPReply(reply)

        // Assert
        XCTAssertNil(parsed)
    }

    func testParseVCPReplyRejectsEmptyData() {
        // Act
        let parsed = DDC.parseVCPReply(Data())

        // Assert
        XCTAssertNil(parsed)
    }

    // MARK: - Capabilities request

    func testCapabilitiesRequestPacket() {
        // Assert: [source, 0x6F, 0xF3, checksum] — 0x51+0x6F+0xF3 = 0x1B3 → checksum 0x4D
        XCTAssertEqual(DDC.capabilitiesRequest, [0x51, 0x6F, 0xF3, 0x4D])
    }

    func testChecksumMakesByteSumZeroMod256() {
        // 0x51 + 0x6C + 0x10 + 0x00 + 0x64 = 0x131 → checksum 0xCF
        XCTAssertEqual(DDC.checksum([0x51, 0x6C, 0x10, 0x00, 0x64]), 0xCF)
        // A packet with its checksum appended sums to 0 mod 256.
        let packet = DDC.writeVCPPacket(code: 0x10, value: 100)
        XCTAssertEqual(packet.reduce(0) { ($0 + Int($1)) & 0xFF }, 0)
    }

    // MARK: - Capabilities text extraction

    func testParseCapabilitiesTextExtractsAsciiPayload() {
        // Arrange
        let payload = Array("vcp(10 12 60 62 8D)F(1)mccs_ver(2.2)".utf8)
        let reply = Data([0x6F, 0xF3, 0x00, 0x2E, 0x00] + payload + [0x6F])

        // Act
        let text = DDC.parseCapabilitiesText(reply)

        // Assert
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("vcp("))
        XCTAssertTrue(text!.contains("mccs_ver(2.2)"))
    }

    func testParseCapabilitiesTextRejectsGarbageData() {
        // Arrange
        let reply = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

        // Act
        let text = DDC.parseCapabilitiesText(reply)

        // Assert
        XCTAssertNil(text)
    }

    func testParseCapabilitiesTextRejectsPayloadWithoutVCPMarker() {
        // Arrange
        let payload = Array("hello world".utf8)
        let reply = Data([0x6F, 0xF3, 0x00, 0x00, 0x00] + payload + [0x6F])

        // Act
        let text = DDC.parseCapabilitiesText(reply)

        // Assert
        XCTAssertNil(text)
    }

    func testParseCapabilitiesTextRejectsTooShortData() {
        // Arrange
        let reply = Data([0x6F, 0xF3])

        // Act
        let text = DDC.parseCapabilitiesText(reply)

        // Assert
        XCTAssertNil(text)
    }

    // MARK: - Capabilities structure parsing

    func testParseCapabilitiesExtractsCodesVersionAndRaw() {
        // Arrange
        let text = "vcp(10 12 60 62 8D)F(1 2)mccs_ver(2.2)"

        // Act
        let caps = DDC.parseCapabilities(text)

        // Assert
        XCTAssertEqual(caps.vcpCodes, Set([0x10, 0x12, 0x60, 0x62, 0x8D]))
        XCTAssertEqual(caps.mccsVersion, "2.2")
        XCTAssertEqual(caps.raw, text)
    }

    func testParseCapabilitiesEmptyTextYieldsEmptyResult() {
        // Act
        let caps = DDC.parseCapabilities("")

        // Assert
        XCTAssertTrue(caps.vcpCodes.isEmpty)
        XCTAssertEqual(caps.mccsVersion, "")
        XCTAssertEqual(caps.raw, "")
    }

    // MARK: - DDCValue normalization

    func testNormalizedComputesRatioOfCurrentToMax() {
        // Arrange
        let value = DDC.DDCValue(maxValue: 100, currentValue: 50)

        // Act
        let normalized = value.normalized

        // Assert
        XCTAssertEqual(normalized, 0.5, accuracy: 0.0001)
    }

    func testNormalizedReturnsZeroWhenMaxIsZero() {
        // Arrange
        let value = DDC.DDCValue(maxValue: 0, currentValue: 50)

        // Act
        let normalized = value.normalized

        // Assert
        XCTAssertEqual(normalized, 0)
    }

    // MARK: - DDCFeature mapping

    func testDDCFeatureVCPCodeMapping() {
        // Assert
        XCTAssertEqual(DDCFeature.brightness.vcpCode, 0x10)
        XCTAssertEqual(DDCFeature.contrast.vcpCode, 0x12)
        XCTAssertEqual(DDCFeature.volume.vcpCode, 0x62)
        XCTAssertEqual(DDCFeature.mute.vcpCode, 0x8D)
        XCTAssertEqual(DDCFeature.inputSource.vcpCode, 0x60)
    }

    func testDDCFeatureContinuousFlags() {
        // Assert
        XCTAssertTrue(DDCFeature.brightness.isContinuous)
        XCTAssertTrue(DDCFeature.contrast.isContinuous)
        XCTAssertTrue(DDCFeature.volume.isContinuous)
        XCTAssertFalse(DDCFeature.mute.isContinuous)
        XCTAssertFalse(DDCFeature.inputSource.isContinuous)
    }
}
