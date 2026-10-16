import XCTest
@testable import FBDCore

final class DDCProtocolTests: XCTestCase {
    // Expected bytes below are derived from m1ddc (github.com/waydabber/m1ddc,
    // sources/i2c.m `prepareDDCWrite` / `prepareDDCRead` / `convertI2CtoDDC`), the
    // reference IOAVService DDC implementation -- not from FBD's earlier assumptions.
    // Hardware verification is still pending (issue #7).

    /// Reply as an IOAVService read returns it: [0x6E, 0x88, 0x02, result, code, type,
    /// maxHi, maxLo, curHi, curLo, chk, pad] (m1ddc reads 12 bytes; max @6-7, current @8-9).
    private func vcpReply(code: UInt8 = 0x10, max: UInt16 = 100, current: UInt16 = 50, result: UInt8 = 0) -> Data {
        Data([0x6E, 0x88, 0x02, result, code, 0x00,
              UInt8(max >> 8), UInt8(max & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF), 0x00, 0x00])
    }

    // MARK: - VCP write packet

    func testWriteVCPPacketMatchesM1DDCSetFeature() {
        // m1ddc: [0x84, 0x03, code, hi, lo, 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ code ^ hi ^ lo]
        // 0x6E^0x51^0x84^0x03^0x10^0x00^0x64 = 0xCC
        XCTAssertEqual(DDC.writeVCPPacket(code: 0x10, value: 100), [0x84, 0x03, 0x10, 0x00, 0x64, 0xCC])
    }

    func testWriteVCPPacketEncodesValueBigEndianAcrossTwoBytes() {
        // 0x6E^0x51^0x84^0x03^0x10 = 0xA8; 0xA8^0x12^0x34 = 0x8E
        XCTAssertEqual(DDC.writeVCPPacket(code: 0x10, value: 0x1234), [0x84, 0x03, 0x10, 0x12, 0x34, 0x8E])
    }

    // MARK: - VCP read request

    func testReadVCPRequestIsSpecFramedGetFeature() {
        // Payload as m1ddc, checksum per DDC/CI: 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ code.
        // 0x6E^0x51^0x82^0x01^0x10 = 0xAC
        XCTAssertEqual(DDC.readVCPRequest(code: 0x10), [0x82, 0x01, 0x10, 0xAC])
    }

    // MARK: - VCP reply parsing

    func testParseVCPReplyReadsMaxAt6And7AndCurrentAt8And9() {
        let parsed = DDC.parseVCPReply(vcpReply(code: 0x10, max: 100, current: 50))

        XCTAssertEqual(parsed?.code, 0x10)
        XCTAssertEqual(parsed?.value, DDC.DDCValue(maxValue: 100, currentValue: 50))
    }

    func testParseVCPReplyDecodesBigEndian16BitValues() {
        let parsed = DDC.parseVCPReply(vcpReply(max: 0x0190, current: 0x0102))

        XCTAssertEqual(parsed?.value, DDC.DDCValue(maxValue: 400, currentValue: 258))
    }

    func testParseVCPReplyRejectsUnsupportedFeatureResult() {
        XCTAssertNil(DDC.parseVCPReply(vcpReply(result: 0x01)))
    }

    func testParseVCPReplyRejectsAllZeroBuffer() {
        // An unanswered read leaves m1ddc's zeroed buffer; it must not parse as 0/0.
        XCTAssertNil(DDC.parseVCPReply(Data(count: DDC.vcpReplyLength)))
    }

    func testParseVCPReplyRejectsShortData() {
        XCTAssertNil(DDC.parseVCPReply(Data([0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64])))
    }

    func testParseVCPReplyRejectsEmptyData() {
        XCTAssertNil(DDC.parseVCPReply(Data()))
    }

    // MARK: - Mute polarity

    func testIsMutedFollowsMCCSPolarity() {
        // VCP 0x8D: 1 = muted (on), 2 = unmuted (off).
        XCTAssertTrue(DDC.isMuted(1))
        XCTAssertFalse(DDC.isMuted(2))
    }

    // MARK: - Capabilities request

    func testCapabilitiesRequestPacket() {
        // [0x83, 0xF3, offHi, offLo, 0x6E^0x51^...]: 0x6E^0x51^0x83^0xF3 = 0x4F
        XCTAssertEqual(DDC.capabilitiesRequest(), [0x83, 0xF3, 0x00, 0x00, 0x4F])
        XCTAssertEqual(DDC.capabilitiesRequest(offset: 0x0020), [0x83, 0xF3, 0x00, 0x20, 0x6F])
    }

    func testChecksumIsXorOfDestinationSourceAndPayload() {
        XCTAssertEqual(DDC.checksum([0x84, 0x03, 0x10, 0x00, 0x64]), 0xCC)
        XCTAssertEqual(DDC.checksum([0x82, 0x01, 0x10], includeSource: false), 0xFD)
    }

    // MARK: - Capabilities fragments

    func testParseCapabilitiesFragmentExtractsOffsetAndPayload() {
        let payload = Array("(vcp(10".utf8)
        let reply = Data([0x6E, UInt8(0x80 | (payload.count + 3)), 0xE3, 0x00, 0x20] + payload + [0x00])

        let fragment = DDC.parseCapabilitiesFragment(reply)

        XCTAssertEqual(fragment?.offset, 0x20)
        XCTAssertEqual(fragment?.payload, payload)
    }

    func testParseCapabilitiesFragmentEmptyPayloadMarksEnd() {
        let fragment = DDC.parseCapabilitiesFragment(Data([0x6E, 0x83, 0xE3, 0x00, 0x40, 0x00]))

        XCTAssertEqual(fragment?.payload, [])
    }

    func testParseCapabilitiesFragmentRejectsWrongOpcodeAndTruncation() {
        XCTAssertNil(DDC.parseCapabilitiesFragment(Data([0x6E, 0x88, 0x02, 0x00, 0x10, 0x00])))
        XCTAssertNil(DDC.parseCapabilitiesFragment(Data([0x6E, 0x90, 0xE3, 0x00, 0x00, 0x41])))
        XCTAssertNil(DDC.parseCapabilitiesFragment(Data([0x6E, 0x83])))
    }

    // MARK: - Capabilities text

    func testParseCapabilitiesTextExtractsAsciiPayload() {
        let text = DDC.parseCapabilitiesText(Data(Array("(vcp(10 12 60 62 8D)F(1)mccs_ver(2.2)".utf8) + [0, 0]))
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("vcp("))
        XCTAssertTrue(text!.contains("mccs_ver(2.2)"))
        XCTAssertFalse(text!.contains("\0"))
    }

    func testParseCapabilitiesTextRejectsGarbageData() {
        XCTAssertNil(DDC.parseCapabilitiesText(Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])))
    }

    func testParseCapabilitiesTextRejectsPayloadWithoutVCPMarker() {
        XCTAssertNil(DDC.parseCapabilitiesText(Data("hello world".utf8)))
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
