import Foundation

/// Decoders for the DisplayPort Configuration Data block.
///
/// These are **pure**: they turn bytes into a structure and never touch AUX, the
/// IOKit registry or a display. That is deliberate. The private getters that read
/// DPCD (`IODPDeviceReadDPCD`, `IODPDeviceGetRevisionMajor`, …) are located and
/// `dlsym`-verified, but their **signatures are not known**, and calling one
/// speculatively is not something to do against a machine's only attached
/// display. So the decoding half is built and tested here first; the read half is
/// a separate step that needs those signatures.
///
/// Register addresses are the DisplayPort specification's. Every conversion that
/// is easy to get subtly wrong is applied in exactly one place, with the rule
/// named (see `maxSlicesPerLine` — stored as *count − 1* — and `maxBitsPerPixel`
/// — stored in 1/16 bpp units). A conversion that could not be confirmed is
/// deliberately **not** applied: `maxLineWidthRaw` is exposed as the stored word
/// rather than presented as a pixel count, so nothing here claims more precision
/// than it has.
///
/// Nothing here has been checked against a live dump, because there is not one
/// yet — no read path exists. The check to run later is a decode of a known-good
/// dump; `DPCDReport.decode` is bounds-checked so a partial dump degrades instead
/// of trapping.
public enum DPCDRegisters {
    /// DPCD_REV — major in bits 7:4, minor in bits 3:0.
    public static let revision = 0x0000
    /// MAX_LINK_RATE — a link-rate code.
    public static let maxLinkRate = 0x0001
    /// MAX_LANE_COUNT — lane count in bits 4:0, TPS3 in bit 6, enhanced frame in bit 7.
    public static let maxLaneCount = 0x0002

    /// DSC capability block.
    public static let dscSupport = 0x0060
    public static let dscMaxSliceCount = 0x0062
    public static let dscMaxLineWidth = 0x0064
    public static let dscColorDepth = 0x0066
    public static let dscEncoding = 0x0067
    public static let dscBlockPrediction = 0x0068
    public static let dscMaxBitsPerPixel = 0x0069

    /// Link status block.
    public static let lane01Status = 0x0202
    public static let lane23Status = 0x0203
    public static let laneAlignStatusUpdated = 0x0204

    /// HDCP 1.3 BSTATUS.
    public static let hdcpBStatus = 0x68028
}

/// A bounds-checked view of a DPCD dump.
///
/// A dump is naturally a set of ranges rather than one flat block: the capability
/// block sits near 0, link status at 0x0202, and HDCP's BSTATUS at 0x68028. So the
/// buffer holds segments, and a read that falls outside every segment returns nil.
/// Nothing is zero-filled — "not read" and "read as zero" are different claims,
/// and a report must not confuse one for the other.
public struct DPCDBuffer: Equatable {
    public struct Segment: Equatable {
        public let start: Int
        public let bytes: [UInt8]

        public init(start: Int, bytes: [UInt8]) {
            self.start = start
            self.bytes = bytes
        }
    }

    public let segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    /// One contiguous block, starting at `startingAt` (0 for the main DPCD block).
    public init(_ bytes: [UInt8], startingAt start: Int = 0) {
        self.segments = bytes.isEmpty ? [] : [Segment(start: start, bytes: bytes)]
    }

    private func location(of address: Int) -> (segment: Segment, offset: Int)? {
        for segment in segments
        where address >= segment.start && address < segment.start + segment.bytes.count {
            return (segment, address - segment.start)
        }
        return nil
    }

    public func byte(at address: Int) -> UInt8? {
        guard address >= 0, let found = location(of: address) else { return nil }
        return found.segment.bytes[found.offset]
    }

    /// A 16-bit register, low byte first, as DPCD stores them.
    ///
    /// Both bytes must come from the same segment: a value assembled from two
    /// separate reads would be a number no device ever reported.
    public func word(at address: Int) -> UInt16? {
        guard let found = location(of: address),
              found.offset + 1 < found.segment.bytes.count else { return nil }
        return UInt16(found.segment.bytes[found.offset])
            | (UInt16(found.segment.bytes[found.offset + 1]) << 8)
    }

    /// The stored bytes covering a range, for parts that are not decoded.
    public func hex(from address: Int, count: Int) -> String? {
        guard count > 0, address >= 0, let found = location(of: address),
              found.offset + count <= found.segment.bytes.count else { return nil }
        return found.segment.bytes[found.offset..<(found.offset + count)]
            .map { String(format: "%02x", $0) }
            .joined(separator: " ")
    }
}

// MARK: - Sink capabilities

public struct DPCDRevision: Equatable {
    public let major: Int
    public let minor: Int

    public init?(byte value: UInt8) {
        // A zero revision means "no DPCD here" rather than version 0.0.
        guard value != 0 else { return nil }
        self.major = Int(value >> 4)
        self.minor = Int(value & 0x0F)
    }

    public var description: String { "\(major).\(minor)" }
}

/// The link rates that have a fixed DPCD code.
///
/// Anything else decodes to nil and is reported as an unknown code. DP 2.x's
/// UHBR rates use different codes that are not reproduced here from memory — the
/// raw byte is kept so the report stays truthful about what the sink said.
public enum DPLinkRate: String, CaseIterable, Sendable {
    case rbr
    case hbr
    case hbr2
    case hbr3

    public var dpcdCode: UInt8 {
        switch self {
        case .rbr: return 0x06
        case .hbr: return 0x0A
        case .hbr2: return 0x14
        case .hbr3: return 0x1E
        }
    }

    public var name: String {
        switch self {
        case .rbr: return "RBR"
        case .hbr: return "HBR"
        case .hbr2: return "HBR2"
        case .hbr3: return "HBR3"
        }
    }

    /// Gbps per lane, as the rate is conventionally quoted.
    public var gigabitsPerLane: Double {
        switch self {
        case .rbr: return 1.62
        case .hbr: return 2.70
        case .hbr2: return 5.40
        case .hbr3: return 8.10
        }
    }

    public init?(dpcdCode: UInt8) {
        guard let match = DPLinkRate.allCases.first(where: { $0.dpcdCode == dpcdCode }) else {
            return nil
        }
        self = match
    }
}

public struct DPSinkCapabilities: Equatable {
    public let revision: DPCDRevision?
    public let maxLinkRateRaw: UInt8?
    public let maxLinkRate: DPLinkRate?
    public let maxLaneCount: Int?
    /// Bit 6 of MAX_LANE_COUNT: supports the TPS3 training pattern (needed for HBR2+).
    public let supportsTPS3: Bool
    /// Bit 7 of MAX_LANE_COUNT: supports the enhanced frame sequence.
    public let supportsEnhancedFrame: Bool

    /// Total payload bandwidth the capability block implies, in Gbps.
    ///
    /// Only meaningful for a rate with a known code; nil otherwise, rather than
    /// assuming a lane width for an unknown rate.
    public var totalGigabitsPerSecond: Double? {
        guard let rate = maxLinkRate, let lanes = maxLaneCount, lanes > 0 else { return nil }
        return rate.gigabitsPerLane * Double(lanes)
    }

    public init(_ buffer: DPCDBuffer) {
        if let raw = buffer.byte(at: DPCDRegisters.revision) {
            revision = DPCDRevision(byte: raw)
        } else {
            revision = nil
        }
        maxLinkRateRaw = buffer.byte(at: DPCDRegisters.maxLinkRate)
        maxLinkRate = maxLinkRateRaw.flatMap(DPLinkRate.init(dpcdCode:))
        if let laneByte = buffer.byte(at: DPCDRegisters.maxLaneCount) {
            let lanes = Int(laneByte & 0x1F)
            maxLaneCount = lanes > 0 ? lanes : nil
            supportsTPS3 = laneByte & 0x40 != 0
            supportsEnhancedFrame = laneByte & 0x80 != 0
        } else {
            maxLaneCount = nil
            supportsTPS3 = false
            supportsEnhancedFrame = false
        }
    }
}

// MARK: - Link status

public struct DPLaneStatus: Equatable {
    /// One lane's training state. Each lane's four status bits sit in its own
    /// nibble of the LANE0_1_STATUS / LANE2_3_STATUS registers.
    public struct Lane: Equatable {
        public let clockRecoveryDone: Bool
        public let channelEqualisationDone: Bool
        public let symbolLock: Bool
        public let interlaneAlignDone: Bool

        /// The commonly used summary: clock recovery, equalisation and symbol
        /// lock all done. Alignment is reported separately because a link can be
        /// trained yet still not aligned.
        public var isTrained: Bool {
            clockRecoveryDone && channelEqualisationDone && symbolLock
        }
    }

    /// Lane number → state, for the lanes the dump actually covered.
    public let lanes: [Int: Lane]
    /// LANE_ALIGN_STATUS_UPDATED bit 6.
    public let interlaneAlignDone: Bool?

    public init(_ buffer: DPCDBuffer) {
        var lanes: [Int: Lane] = [:]
        // Lanes 0 and 1 share one register, 2 and 3 share the next.
        for (register, firstLane) in [
            (DPCDRegisters.lane01Status, 0),
            (DPCDRegisters.lane23Status, 2),
        ] {
            guard let value = buffer.byte(at: register) else { continue }
            for offset in 0..<2 {
                let nibble = (value >> UInt8(offset * 4)) & 0x0F
                lanes[firstLane + offset] = Lane(
                    clockRecoveryDone: nibble & 0x1 != 0,
                    channelEqualisationDone: nibble & 0x2 != 0,
                    symbolLock: nibble & 0x4 != 0,
                    interlaneAlignDone: nibble & 0x8 != 0
                )
            }
        }
        self.lanes = lanes
        if let align = buffer.byte(at: DPCDRegisters.laneAlignStatusUpdated) {
            interlaneAlignDone = align & 0x40 != 0
        } else {
            interlaneAlignDone = nil
        }
    }

    /// Lanes reported trained, in lane order. A link is up when this covers every
    /// lane the sink advertised, which is the caller's comparison to make.
    public var trainedLanes: [Int] {
        lanes.filter { $0.value.isTrained }.keys.sorted()
    }

    /// The highest lane number present, +1 — the lane count the status covers.
    public var laneCount: Int {
        (lanes.keys.max() ?? -1) + 1
    }
}

// MARK: - DSC

public struct DSCSinkCapabilities: Equatable {
    public let supported: Bool
    /// DPCD stores slices-per-line as *count − 1*, so the conversion is applied
    /// here and nowhere else.
    public let maxSlicesPerLine: Int?
    /// The stored word, in the unit the specification defines but that is not
    /// converted here — reported raw rather than presented as a pixel count.
    public let maxLineWidthRaw: UInt16?
    /// Bits per component the sink accepts, from the DSC colour-depth flags.
    public let bitsPerComponent: [Int]
    /// Pixel encodings the sink accepts, in the flag order the register uses.
    public let encodings: [String]
    public let blockPrediction: Bool
    /// DPCD stores this in 1/16 bpp units, so the conversion is applied here.
    public let maxBitsPerPixel: Double?

    public init(_ buffer: DPCDBuffer) {
        let support = buffer.byte(at: DPCDRegisters.dscSupport)
        supported = support.map { $0 & 0x01 != 0 } ?? false

        if let raw = buffer.word(at: DPCDRegisters.dscMaxSliceCount) {
            maxSlicesPerLine = Int(raw) + 1
        } else {
            maxSlicesPerLine = nil
        }
        maxLineWidthRaw = buffer.word(at: DPCDRegisters.dscMaxLineWidth)

        if let depth = buffer.byte(at: DPCDRegisters.dscColorDepth) {
            var depths: [Int] = []
            if depth & 0x01 != 0 { depths.append(8) }
            if depth & 0x02 != 0 { depths.append(10) }
            if depth & 0x04 != 0 { depths.append(12) }
            bitsPerComponent = depths
        } else {
            bitsPerComponent = []
        }

        if let encoding = buffer.byte(at: DPCDRegisters.dscEncoding) {
            var found: [String] = []
            if encoding & 0x01 != 0 { found.append("RGB") }
            if encoding & 0x02 != 0 { found.append("YCbCr 4:4:4") }
            if encoding & 0x04 != 0 { found.append("YCbCr 4:2:2") }
            if encoding & 0x08 != 0 { found.append("YCbCr 4:2:0") }
            if encoding & 0x10 != 0 { found.append("native") }
            encodings = found
        } else {
            encodings = []
        }

        blockPrediction = buffer.byte(at: DPCDRegisters.dscBlockPrediction).map { $0 & 0x01 != 0 } ?? false
        if let raw = buffer.word(at: DPCDRegisters.dscMaxBitsPerPixel) {
            maxBitsPerPixel = Double(raw) / 16
        } else {
            maxBitsPerPixel = nil
        }
    }
}

// MARK: - HDCP

public struct HDCPStatus: Equatable {
    /// BSTATUS bit 0.
    public let linkIntegrityFailure: Bool
    /// BSTATUS bit 1.
    public let reauthenticationRequested: Bool

    public init(byte value: UInt8) {
        linkIntegrityFailure = value & 0x01 != 0
        reauthenticationRequested = value & 0x02 != 0
    }
}

// MARK: - Report

public struct DPCDReport: Equatable {
    public let sink: DPSinkCapabilities
    public let laneStatus: DPLaneStatus?
    public let dsc: DSCSinkCapabilities?
    public let hdcp: HDCPStatus?

    /// Decode a dump. Sections whose bytes are absent are nil rather than
    /// blank-filled, so a partial dump reports "not read" instead of "zero".
    /// Decode a contiguous dump starting at address 0.
    public static func decode(_ bytes: [UInt8]) -> DPCDReport {
        decode(DPCDBuffer(bytes))
    }

    public static func decode(_ buffer: DPCDBuffer) -> DPCDReport {
        let hasDSC = buffer.byte(at: DPCDRegisters.dscSupport) != nil
        let hasLanes = buffer.byte(at: DPCDRegisters.lane01Status) != nil
        return DPCDReport(
            sink: DPSinkCapabilities(buffer),
            laneStatus: hasLanes ? DPLaneStatus(buffer) : nil,
            dsc: hasDSC ? DSCSinkCapabilities(buffer) : nil,
            hdcp: buffer.byte(at: DPCDRegisters.hdcpBStatus).map(HDCPStatus.init(byte:))
        )
    }

    public init(
        sink: DPSinkCapabilities,
        laneStatus: DPLaneStatus?,
        dsc: DSCSinkCapabilities?,
        hdcp: HDCPStatus?
    ) {
        self.sink = sink
        self.laneStatus = laneStatus
        self.dsc = dsc
        self.hdcp = hdcp
    }

    private static func yesno(_ value: Bool) -> String { value ? "yes" : "no" }

    /// A fixed-shape report. Every "not read" is spelled out rather than left
    /// blank, because a blank line reads as "no capability" and that is a
    /// different claim.
    public func render() -> String {
        var lines: [String] = []
        lines.append("DPCD")
        lines.append("  revision: \(sink.revision?.description ?? "not read")")

        if let raw = sink.maxLinkRateRaw {
            let named = sink.maxLinkRate.map { "\($0.name) (\($0.gigabitsPerLane) Gbps/lane)" } ?? "unknown code"
            let hex = String(format: "0x%02x", raw)
            lines.append("  max link rate: \(hex) — \(named)")
        } else {
            lines.append("  max link rate: not read")
        }
        lines.append("  max lane count: \(sink.maxLaneCount.map(String.init) ?? "not read")")
        if let total = sink.totalGigabitsPerSecond {
            lines.append("  capability bandwidth: \(total) Gbps total")
        }
        if sink.maxLaneCount != nil {
            lines.append("  TPS3: \(Self.yesno(sink.supportsTPS3)), enhanced frame: \(Self.yesno(sink.supportsEnhancedFrame))")
        }

        if let laneStatus {
            if laneStatus.lanes.isEmpty {
                lines.append("  lanes: not read")
            } else {
                let trained = laneStatus.trainedLanes
                lines.append("  lanes trained: \(trained.isEmpty ? "none" : trained.map(String.init).joined(separator: ", ")) of \(laneStatus.laneCount)")
                for lane in laneStatus.lanes.keys.sorted() {
                    guard let state = laneStatus.lanes[lane] else { continue }
                    lines.append("    lane \(lane): clock recovery \(Self.yesno(state.clockRecoveryDone))"
                        + ", equalisation \(Self.yesno(state.channelEqualisationDone))"
                        + ", symbol lock \(Self.yesno(state.symbolLock))"
                        + ", interlane align \(Self.yesno(state.interlaneAlignDone))")
                }
                lines.append("  interlane align done: \(laneStatus.interlaneAlignDone.map(Self.yesno) ?? "not read")")
            }
        } else {
            lines.append("  lanes: not read")
        }

        if let dsc {
            lines.append("  DSC supported: \(Self.yesno(dsc.supported))")
            if dsc.supported {
                lines.append("    max slices per line: \(dsc.maxSlicesPerLine.map(String.init) ?? "not read")")
                lines.append("    max line width (raw): \(dsc.maxLineWidthRaw.map(String.init) ?? "not read")")
                let depths = dsc.bitsPerComponent.map { "\($0) bpc" }.joined(separator: ", ")
                lines.append("    bits per component: \(depths.isEmpty ? "none advertised" : depths)")
                lines.append("    encodings: \(dsc.encodings.isEmpty ? "none advertised" : dsc.encodings.joined(separator: ", "))")
                lines.append("    block prediction: \(Self.yesno(dsc.blockPrediction))")
                if let bpp = dsc.maxBitsPerPixel {
                    lines.append("    max bits per pixel: \(bpp)")
                }
            }
        } else {
            lines.append("  DSC: not read")
        }

        if let hdcp {
            lines.append("  HDCP: link integrity failure \(Self.yesno(hdcp.linkIntegrityFailure))"
                + ", reauthentication requested \(Self.yesno(hdcp.reauthenticationRequested))")
        } else {
            lines.append("  HDCP: not read")
        }
        return lines.joined(separator: "\n")
    }
}
