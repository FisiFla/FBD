import XCTest
@testable import FBDCore

final class DDCProtocolTests: XCTestCase {
    // Expected bytes below are derived from m1ddc (github.com/waydabber/m1ddc,
    // sources/i2c.m `prepareDDCWrite` / `prepareDDCRead` / `convertI2CtoDDC`), the
    // reference IOAVService DDC implementation -- not from FBD's earlier assumptions.
    // Hardware verification is still pending (issue #7).

    /// Reply as an IOAVService read returns it: [0x6E, 0x88, 0x02, result, code, type,
    /// maxHi, maxLo, curHi, curLo, chk, pad] (m1ddc reads 12 bytes; max @6-7, current @8-9).
    ///
    /// The checksum byte is the display's bus address (0x50) XORed over the frame —
    /// `DDC.replyChecksum`, the same rule didriksg/Crisp v1.7.1 applies.
    private func vcpReply(code: UInt8 = 0x10, max: UInt16 = 100, current: UInt16 = 50, result: UInt8 = 0) -> Data {
        let frame: [UInt8] = [0x6E, 0x88, 0x02, result, code, 0x00,
                              UInt8(max >> 8), UInt8(max & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
        return Data(frame + [DDC.replyChecksum(frame), 0x00])
    }

    /// The same frame, with one byte replaced, and a recomputed checksum.
    private func vcpReply(patching index: Int, _ byte: UInt8, code: UInt8 = 0x10) -> Data {
        var frame: [UInt8] = [0x6E, 0x88, 0x02, 0x00, code, 0x00, 0x00, 0x64, 0x00, 0x32]
        frame[index] = byte
        return Data(frame + [DDC.replyChecksum(frame), 0x00])
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

    // MARK: - VCP reply validation

    func testReplyChecksumMatchesTheCrispVector() {
        // The canonical frame [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32]
        // checksums to 0xF2 with the display's bus address (0x50) as the seed.
        let frame: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32]
        XCTAssertEqual(DDC.replyChecksum(frame), 0xF2)
        // The request checksum uses a different seed (0x6E ^ 0x51) and must not
        // be used on replies.
        XCTAssertNotEqual(DDC.checksum(frame), DDC.replyChecksum(frame))
    }

    func testValidateVCPReplyAcceptsAWellFormedReply() {
        XCTAssertNil(DDC.validateVCPReply(vcpReply(code: 0x10), expecting: 0x10))
    }

    func testValidateVCPReplyRejectsATooShortFrame() {
        XCTAssertEqual(DDC.validateVCPReply(Data([0x6E, 0x88, 0x02])), .tooShort(3))
    }

    func testValidateVCPReplyRejectsAMissingSignature() {
        // Stale EDID bytes start with 0x00 — the reply has to start with 0x6E.
        XCTAssertEqual(DDC.validateVCPReply(vcpReply(patching: 0, 0x00)), .badSignature(0x00))
    }

    func testValidateVCPReplyRejectsAWrongOpcode() {
        XCTAssertEqual(DDC.validateVCPReply(vcpReply(patching: 2, 0x03)), .badOpcode(0x03))
    }

    func testValidateVCPReplyRejectsANonZeroResultCode() {
        // Result 1 = "the display does not support this VCP feature".
        XCTAssertEqual(DDC.validateVCPReply(vcpReply(result: 0x01)), .badResult(0x01))
    }

    func testValidateVCPReplyRejectsAnEchoOfAnotherFeature() {
        XCTAssertEqual(
            DDC.validateVCPReply(vcpReply(code: 0x12), expecting: 0x10),
            .badEcho(expected: 0x10, actual: 0x12)
        )
    }

    func testValidateVCPReplyRejectsABrokenChecksum() {
        var bytes = [UInt8](vcpReply(code: 0x10))
        bytes[10] = bytes[10] ^ 0xFF
        XCTAssertEqual(
            DDC.validateVCPReply(Data(bytes), expecting: 0x10),
            .badChecksum(expected: DDC.replyChecksum(Array(bytes[0..<10])), actual: bytes[10])
        )
    }

    func testValidateVCPReplyRejectsAZeroMaximumForAScaledFeature() {
        // A zero maximum would scale every write to that feature to zero.
        XCTAssertEqual(DDC.validateVCPReply(vcpReply(code: 0x10, max: 0)), .zeroMaximum)
    }

    func testValidateVCPReplyAcceptsAZeroMaximumForTheInputSource() {
        // The input source has no scale; some monitors report a maximum of zero.
        XCTAssertNil(DDC.validateVCPReply(vcpReply(code: 0x60, max: 0), expecting: 0x60))
    }

    func testParseVCPReplyRejectsAFrameThatOnlyPassesTheHeader() {
        // The classic failure: a display acknowledges the I2C read and answers
        // with stale bytes. The header looks right, the checksum does not.
        var bytes = [UInt8](vcpReply(code: 0x10))
        bytes[10] = 0x00
        XCTAssertNil(DDC.parseVCPReply(Data(bytes), expecting: 0x10))
    }

    func testParseVCPReplyRejectsAZeroMaximumForAScaledFeature() {
        XCTAssertNil(DDC.parseVCPReply(vcpReply(code: 0x10, max: 0), expecting: 0x10))
    }

    func testParseVCPReplyAcceptsAZeroMaximumForTheInputSource() {
        let parsed = DDC.parseVCPReply(vcpReply(code: 0x60, max: 0, current: 3), expecting: 0x60)
        XCTAssertEqual(parsed?.code, 0x60)
        XCTAssertEqual(parsed?.value.currentValue, 3)
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
