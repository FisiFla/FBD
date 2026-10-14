import XCTest
@testable import FBDCore

/// Row #24: the DPCD/DSC decoders. Everything here is pure — no AUX, no IOKit,
/// no display — which is the whole point of doing the decoding half before the
/// read half, whose private signatures are still unidentified.
final class DPCDReportTests: XCTestCase {
    /// A dense block up to `end`, with the given addresses set. Convenient for the
    /// low registers; HDCP's BSTATUS is a separate segment because it is 400 kB
    /// away in address space.
    private func block(_ values: [Int: UInt8], upTo end: Int) -> DPCDBuffer {
        var bytes = [UInt8](repeating: 0, count: end + 1)
        for (address, value) in values { bytes[address] = value }
        return DPCDBuffer(bytes)
    }

    // MARK: - Revision

    func testRevisionSplitsIntoMajorAndMinorNibbles() {
        XCTAssertEqual(DPCDRevision(byte: 0x14)?.major, 1)
        XCTAssertEqual(DPCDRevision(byte: 0x14)?.minor, 4)
        XCTAssertEqual(DPCDRevision(byte: 0x24)?.description, "2.4")
    }

    func testAZeroRevisionMeansNoDpcdRatherThanVersionZeroZero() {
        XCTAssertNil(DPCDRevision(byte: 0))
    }

    // MARK: - Link rate

    func testEveryLinkRateRoundTripsThroughItsCode() {
        for rate in DPLinkRate.allCases {
            XCTAssertEqual(DPLinkRate(dpcdCode: rate.dpcdCode), rate)
        }
    }

    func testTheKnownCodesDecodeToTheirRates() {
        XCTAssertEqual(DPLinkRate(dpcdCode: 0x06), .rbr)
        XCTAssertEqual(DPLinkRate(dpcdCode: 0x0A), .hbr)
        XCTAssertEqual(DPLinkRate(dpcdCode: 0x14), .hbr2)
        XCTAssertEqual(DPLinkRate(dpcdCode: 0x1E), .hbr3)
    }

    /// The DP 2.x UHBR codes are deliberately not reproduced from memory, so an
    /// unknown code stays unknown and the raw byte is what the report keeps.
    func testAnUnknownRateCodeIsNotGuessedAt() {
        XCTAssertNil(DPLinkRate(dpcdCode: 0x01))
        let report = DPCDReport.decode(block([0x0001: 0x01], upTo: 0x0002))
        XCTAssertNil(report.sink.maxLinkRate)
        XCTAssertEqual(report.sink.maxLinkRateRaw, 0x01)
        XCTAssertTrue(report.render().contains("unknown code"))
    }

    // MARK: - Sink capabilities

    func testLaneCountIgnoresTheCapabilityFlagBits() {
        // 0x84 = enhanced frame (bit 7) + 4 lanes.
        let report = DPCDReport.decode(block([0x0002: 0x84], upTo: 0x0002))
        XCTAssertEqual(report.sink.maxLaneCount, 4)
        XCTAssertTrue(report.sink.supportsEnhancedFrame)
        XCTAssertFalse(report.sink.supportsTPS3)
    }

    func testTPS3IsReadFromItsOwnBit() {
        let report = DPCDReport.decode(block([0x0002: 0x42], upTo: 0x0002))
        XCTAssertEqual(report.sink.maxLaneCount, 2)
        XCTAssertTrue(report.sink.supportsTPS3)
    }

    func testASinkAdvertisingZeroLanesReportsNoLaneCount() {
        XCTAssertNil(DPCDReport.decode(block([0x0002: 0x00], upTo: 0x0002)).sink.maxLaneCount)
    }

    func testTotalBandwidthIsRateTimesLanes() {
        let report = DPCDReport.decode(block([0x0001: 0x1E, 0x0002: 0x04], upTo: 0x0002))
        XCTAssertEqual(report.sink.totalGigabitsPerSecond ?? 0, 32.4, accuracy: 0.001)
    }

    func testBandwidthIsNilWithoutAKnownRateRatherThanAssumingOne() {
        let report = DPCDReport.decode(block([0x0001: 0x01, 0x0002: 0x04], upTo: 0x0002))
        XCTAssertNil(report.sink.totalGigabitsPerSecond)
    }

    // MARK: - Lane status

    func testLaneStatusReadsOneNibblePerLane() throws {
        // 0x77: lanes 0 and 1 have clock recovery, equalisation and symbol lock but
        // not interlane align. 0x0F: lane 2 has every bit, lane 3 none of them.
        let report = DPCDReport.decode(block([0x0202: 0x77, 0x0203: 0x0F], upTo: 0x0203))
        let lanes = try XCTUnwrap(report.laneStatus)
        XCTAssertEqual(lanes.trainedLanes, [0, 1, 2])
        XCTAssertEqual(lanes.laneCount, 4)
        XCTAssertEqual(lanes.lanes[2]?.interlaneAlignDone, true)
        XCTAssertEqual(lanes.lanes[3]?.isTrained, false)
    }

    func testInterlaneAlignComesFromTheStatusUpdatedRegister() {
        let aligned = DPCDReport.decode(block([0x0202: 0x0F, 0x0204: 0x40], upTo: 0x0204))
        XCTAssertEqual(aligned.laneStatus?.interlaneAlignDone, true)
        let unaligned = DPCDReport.decode(block([0x0202: 0x0F, 0x0204: 0x00], upTo: 0x0204))
        XCTAssertEqual(unaligned.laneStatus?.interlaneAlignDone, false)
    }

    // MARK: - DSC

    func testSlicesPerLineAppliesTheStoredMinusOneRule() {
        let report = DPCDReport.decode(block([
            DPCDRegisters.dscSupport: 0x01,
            DPCDRegisters.dscMaxSliceCount: 0x03,
        ], upTo: DPCDRegisters.dscMaxSliceCount + 1))
        XCTAssertEqual(report.dsc?.maxSlicesPerLine, 4)
    }

    func testBitsPerPixelReadsTheSixteenthsUnit() {
        let report = DPCDReport.decode(block([
            DPCDRegisters.dscSupport: 0x01,
            DPCDRegisters.dscMaxBitsPerPixel: 0x80,
        ], upTo: DPCDRegisters.dscMaxBitsPerPixel + 1))
        XCTAssertEqual(report.dsc?.maxBitsPerPixel ?? 0, 8.0, accuracy: 0.0001)
    }

    func testColourDepthAndEncodingFlagsDecodeInFlagOrder() {
        let report = DPCDReport.decode(block([
            DPCDRegisters.dscSupport: 0x01,
            DPCDRegisters.dscColorDepth: 0x05,
            DPCDRegisters.dscEncoding: 0x0C,
        ], upTo: DPCDRegisters.dscEncoding))
        XCTAssertEqual(report.dsc?.bitsPerComponent, [8, 12])
        XCTAssertEqual(report.dsc?.encodings, ["YCbCr 4:2:2", "YCbCr 4:2:0"])
    }

    func testABlockPredictionBitIsReported() {
        let report = DPCDReport.decode(block([
            DPCDRegisters.dscSupport: 0x01,
            DPCDRegisters.dscBlockPrediction: 0x01,
        ], upTo: DPCDRegisters.dscBlockPrediction))
        XCTAssertEqual(report.dsc?.blockPrediction, true)
    }

    /// A sink that does not claim DSC gets no detail lines — reporting "slices: 0"
    /// for a sink with no DSC would be a fabricated capability.
    func testASinkWithoutDscReportsUnsupported() {
        let report = DPCDReport.decode(block([DPCDRegisters.dscSupport: 0x00], upTo: DPCDRegisters.dscSupport))
        XCTAssertEqual(report.dsc?.supported, false)
        let text = report.render()
        XCTAssertTrue(text.contains("DSC supported: no"))
        XCTAssertFalse(text.contains("max slices per line"))
    }

    // MARK: - HDCP, a segment of its own

    func testHdcpStatusComesFromItsOwnSegment() {
        let buffer = DPCDBuffer(segments: [
            DPCDBuffer.Segment(start: DPCDRegisters.hdcpBStatus, bytes: [0x03]),
        ])
        let report = DPCDReport.decode(buffer)
        XCTAssertEqual(report.hdcp, HDCPStatus(byte: 0x03))
        XCTAssertTrue(report.render().contains("HDCP: link integrity failure yes"))
    }

    // MARK: - Partial and empty dumps

    func testAnEmptyDumpDecodesToNothingRatherThanZeros() {
        let report = DPCDReport.decode([UInt8]())
        XCTAssertNil(report.sink.revision)
        XCTAssertNil(report.sink.maxLinkRateRaw)
        XCTAssertNil(report.sink.maxLaneCount)
        XCTAssertNil(report.laneStatus)
        XCTAssertNil(report.dsc)
        XCTAssertNil(report.hdcp)
    }

    /// "Not read" and "read as zero" are different claims, so the report spells the
    /// first one out instead of leaving a blank that reads as the second.
    func testTheReportSaysNotReadRatherThanLeavingBlanks() {
        let text = DPCDReport.decode([UInt8]()).render()
        XCTAssertTrue(text.contains("revision: not read"))
        XCTAssertTrue(text.contains("lanes: not read"))
        XCTAssertTrue(text.contains("DSC: not read"))
        XCTAssertTrue(text.contains("HDCP: not read"))
    }

    /// What a caller that read only the first three registers actually has.
    func testACapabilityOnlyDumpHasNoLaneStatus() {
        let report = DPCDReport.decode(block([0x0000: 0x14, 0x0001: 0x1E, 0x0002: 0x04], upTo: 0x0002))
        XCTAssertEqual(report.sink.revision?.description, "1.4")
        XCTAssertNil(report.laneStatus, "a three-byte read cannot know the lane state")
    }

    func testAWordIsNeverAssembledAcrossASegmentGap() {
        let buffer = DPCDBuffer(segments: [
            DPCDBuffer.Segment(start: 0x0062, bytes: [0x03]),
            DPCDBuffer.Segment(start: 0x0063, bytes: [0x00]),
        ])
        XCTAssertNil(buffer.word(at: 0x0062), "the low byte and high byte came from different reads")
        XCTAssertEqual(buffer.byte(at: 0x0063), 0x00)
    }

    func testReadingBeforeTheStartOfASegmentIsNotAnAnswer() {
        let buffer = DPCDBuffer([0x14, 0x1E], startingAt: 0x0000)
        XCTAssertEqual(buffer.byte(at: 0x0000), 0x14)
        XCTAssertNil(buffer.byte(at: -1))
        XCTAssertNil(buffer.byte(at: 0x0002))
    }

    // MARK: - The rendered report is a fixed shape

    func testRenderedReportIsStableForAFullDump() {
        let report = DPCDReport.decode(block([
            0x0000: 0x14,
            0x0001: 0x1E,
            0x0002: 0x84,
            0x0060: 0x01,
            0x0062: 0x03,
            0x0066: 0x03,
            0x0067: 0x01,
            0x0068: 0x01,
            0x0069: 0x80,
            0x0202: 0x77,
            0x0203: 0x0F,
            0x0204: 0x40,
        ], upTo: 0x0204))
        let expected = """
        DPCD
          revision: 1.4
          max link rate: 0x1e — HBR3 (8.1 Gbps/lane)
          max lane count: 4
          capability bandwidth: 32.4 Gbps total
          TPS3: no, enhanced frame: yes
          lanes trained: 0, 1, 2 of 4
            lane 0: clock recovery yes, equalisation yes, symbol lock yes, interlane align no
            lane 1: clock recovery yes, equalisation yes, symbol lock yes, interlane align no
            lane 2: clock recovery yes, equalisation yes, symbol lock yes, interlane align yes
            lane 3: clock recovery no, equalisation no, symbol lock no, interlane align no
          interlane align done: yes
          DSC supported: yes
            max slices per line: 4
            max line width (raw): 0
            bits per component: 8 bpc, 10 bpc
            encodings: RGB
            block prediction: yes
            max bits per pixel: 8.0
          HDCP: not read
        """
        XCTAssertEqual(report.render(), expected)
    }
}
