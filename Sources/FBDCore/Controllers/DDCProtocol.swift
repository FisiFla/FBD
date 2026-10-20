import Foundation

// MARK: - DDC/CI protocol constants and wire format (pure logic, unit-tested)

public enum DDC {
    /// DDC/CI I2C bus address.
    public static let i2cAddress: UInt8 = 0x37
    /// EDID I2C bus address.
    public static let edidAddress: UInt8 = 0x50
    /// Source address used in DDC write transactions (host).
    public static let sourceAddress: UInt8 = 0x51

    /// VCP feature codes (VESA MCCS). Only the subset FBD uses is enumerated.
    public enum VCPCode: UInt8, CaseIterable {
        case brightness = 0x10
        case contrast = 0x12
        case colorPreset = 0x14
        case redGain = 0x16
        case greenGain = 0x18
        case blueGain = 0x1A
        case inputSource = 0x60
        case speakerVolume = 0x62
        case audioMute = 0x8D
        case osd = 0xCA
        case dpms = 0xD6
        /// Special read-only feature returning the capabilities string (VCP 0xF3).
        case capabilities = 0xF3
    }

    /// Result of a VCP read.
    public struct DDCValue: Equatable {
        public let maxValue: UInt16
        public let currentValue: UInt16

        public init(maxValue: UInt16, currentValue: UInt16) {
            self.maxValue = maxValue
            self.currentValue = currentValue
        }

        /// 0…1 normalized current value.
        public var normalized: Double {
            guard maxValue > 0 else { return 0 }
            return Double(currentValue) / Double(maxValue)
        }
    }

    /// DDC/CI checksum: XOR of the I2C destination (0x6E), optionally the source
    /// address (0x51), and every payload byte.
    ///
    /// Framing here follows m1ddc (github.com/waydabber/m1ddc, sources/i2c.m), the
    /// reference IOAVService DDC implementation. The 0x51 is NOT part of the bytes
    /// handed to IOAVServiceWriteI2C: it is passed as the call's data address
    /// (offset) and the transport puts it on the wire.
    ///
    /// NOTE: hardware verification of this framing is still pending (issue #7); the
    /// code-level equivalence audit against didriksg/Crisp v1.7.1 lives in
    /// `docs/ddc-equivalence.md`.
    public static func checksum(_ payload: [UInt8], includeSource: Bool = true) -> UInt8 {
        payload.reduce(UInt8(0x6E) ^ (includeSource ? sourceAddress : 0)) { $0 ^ $1 }
    }

    // MARK: VCP write

    /// [0x84, 0x03, code, hi, lo, chk] — "set VCP feature" payload, chk = 0x6E ^ 0x51 ^ bytes
    /// (m1ddc `prepareDDCWrite`). Sent to chip 0x37 with data address 0x51.
    public static func writeVCPPacket(code: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, code, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return body + [checksum(body)]
    }

    // MARK: VCP read

    /// [0x82, 0x01, code, chk] — "get VCP feature" payload (m1ddc `prepareDDCRead`).
    /// m1ddc's read checksum omits the 0x51 term its write checksum has; the DDC/CI spec
    /// (and Lunar) include it. Monitors that work with m1ddc evidently ignore the read
    /// checksum, so the spec-correct form is the one that also satisfies strict monitors.
    public static func readVCPRequest(code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, code]
        return body + [checksum(body)]
    }

    /// Bytes to read back for a VCP reply (m1ddc reads 12).
    public static let vcpReplyLength = 12

    /// The DDC/CI signature byte that opens every reply frame.
    public static let replySignature: UInt8 = 0x6E

    /// The bus address of the display, used as the checksum seed of a reply.
    ///
    /// A reply's checksum is seeded with the *display's* address (0x50), not
    /// with the 0x6E signature — which is why it is not `checksum(...)`, whose
    /// seed is 0x6E ^ 0x51 and which is used for the requests we send.
    public static let replyChecksumSeed: UInt8 = 0x50

    /// The checksum of a reply frame: the display's bus address XORed with
    /// every byte of the frame, the 0x6E header byte included.
    public static func replyChecksum(_ frame: [UInt8]) -> UInt8 {
        frame.reduce(replyChecksumSeed) { $0 ^ $1 }
    }

    /// Why a VCP reply was rejected.
    ///
    /// A display can acknowledge an I2C read and still answer with stale EDID
    /// bytes, a NULL frame, or an echo of our own request. Values read from
    /// such a reply poison the write scale — a bogus maximum makes every
    /// brightness write saturate — so a reply has to prove itself before any
    /// of its numbers are used.
    public enum VCPReplyRejection: Equatable {
        /// The frame was shorter than a reply can be.
        case tooShort(Int)
        /// The frame did not start with the 0x6E signature.
        case badSignature(UInt8)
        /// The opcode was not 0x02 ("get VCP feature reply").
        case badOpcode(UInt8)
        /// The result byte was not 0x00 (1 = unsupported VCP feature).
        case badResult(UInt8)
        /// The reply echoed a different VCP code than the one requested.
        case badEcho(expected: UInt8, actual: UInt8)
        /// The frame's checksum did not match its bytes.
        case badChecksum(expected: UInt8, actual: UInt8)
        /// The reply reported a maximum of zero for a scaled feature.
        case zeroMaximum
    }

    /// Validate a VCP reply.
    ///
    /// `expecting` is the VCP code that was requested: the reply has to echo
    /// it, and it decides whether a maximum of zero is acceptable — the input
    /// source has no scale, and some monitors report a zero maximum for it.
    /// When no code is given, the reply's own echo is used for that decision.
    ///
    /// - Returns: the reason the reply was rejected, or nil when it is valid.
    public static func validateVCPReply(
        _ data: Data,
        expecting code: UInt8? = nil
    ) -> VCPReplyRejection? {
        let bytes = [UInt8](data)
        guard bytes.count >= 11 else { return .tooShort(bytes.count) }
        guard bytes[0] == replySignature else { return .badSignature(bytes[0]) }
        guard bytes[2] == 0x02 else { return .badOpcode(bytes[2]) }
        guard bytes[3] == 0x00 else { return .badResult(bytes[3]) }
        if let code, bytes[4] != code { return .badEcho(expected: code, actual: bytes[4]) }
        let expected = replyChecksum(Array(bytes[0 ..< 10]))
        guard expected == bytes[10] else { return .badChecksum(expected: expected, actual: bytes[10]) }
        let maxValue = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let effectiveCode = code ?? bytes[4]
        if maxValue == 0, effectiveCode != VCPCode.inputSource.rawValue {
            return .zeroMaximum
        }
        return nil
    }

    /// Parse a VCP reply.
    ///
    /// The reply has to validate first (see `validateVCPReply`): the numbers in
    /// a frame that does not prove itself are never used, because a display
    /// that answers with stale bytes would otherwise set the write scale for
    /// every write that follows. See `docs/ddc-equivalence.md` for the audit
    /// of this contract against didriksg/Crisp v1.7.1.
    public static func parseVCPReply(
        _ data: Data,
        expecting code: UInt8? = nil
    ) -> (code: UInt8, value: DDCValue)? {
        guard validateVCPReply(data, expecting: code) == nil else { return nil }
        let bytes = [UInt8](data)
        let replyCode = bytes[4]
        let maxValue = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let currentValue = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        return (replyCode, DDCValue(maxValue: maxValue, currentValue: currentValue))
    }

    // MARK: Capabilities

    /// [0x83, 0xF3, offHi, offLo, chk] — "capabilities request" for the fragment at `offset`
    /// (DDC/CI spec; m1ddc has no capabilities support, so the checksum is the spec's
    /// 0x6E ^ 0x51 ^ bytes, as for writes).
    public static func capabilitiesRequest(offset: UInt16 = 0) -> [UInt8] {
        let body: [UInt8] = [0x83, VCPCode.capabilities.rawValue, UInt8(offset >> 8), UInt8(offset & 0xFF)]
        return body + [checksum(body)]
    }

    /// Bytes to read back for one capabilities fragment (header + up to 32 data bytes + checksum).
    public static let capabilitiesReplyLength = 38

    /// One capabilities-reply fragment: [0x6E, 0x80|(n+3), 0xE3, offHi, offLo, n data bytes, chk].
    /// A fragment with no data marks the end of the string.
    public static func parseCapabilitiesFragment(_ data: Data) -> (offset: Int, payload: [UInt8])? {
        let bytes = [UInt8](data)
        guard bytes.count >= 6, bytes[2] == 0xE3 else { return nil }
        let length = Int(bytes[1] & 0x7F)
        guard length >= 3, bytes.count >= 2 + length + 1 else { return nil }
        let offset = Int(bytes[3]) << 8 | Int(bytes[4])
        return (offset, Array(bytes[5 ..< 2 + length]))
    }

    /// The capabilities text from the assembled fragment payload bytes (trailing NULs ignored).
    public static func parseCapabilitiesText(_ data: Data) -> String? {
        let trimmed = data.prefix { $0 != 0 }
        let text = String(decoding: trimmed, as: UTF8.self)
        // Capability text is printable ASCII; bail out if we picked up garbage.
        guard text.range(of: "vcp(", options: .caseInsensitive) != nil else { return nil }
        return text
    }

    /// Parsed capabilities: VCP feature set + MCCS version, per the VESA
    /// DisplayID/DDC "capabilities reply" grammar: `vcp(10 12 60 62 8D)F(1 2)mccs_ver(2.2)`.
    public struct DDCCapabilities: Equatable {
        public let mccsVersion: String
        public let vcpCodes: Set<UInt8>
        public let raw: String

        public init(mccsVersion: String, vcpCodes: Set<UInt8>, raw: String) {
            self.mccsVersion = mccsVersion
            self.vcpCodes = vcpCodes
            self.raw = raw
        }

        public func supports(_ code: UInt8) -> Bool { vcpCodes.contains(code) }
        public func supports(_ code: VCPCode) -> Bool { vcpCodes.contains(code.rawValue) }
    }

    public static func parseCapabilities(_ text: String) -> DDCCapabilities {
        var mccsVersion = ""
        var codes = Set<UInt8>()
        let nsText = text as NSString
        if let range = nsText.range(of: #"mccs_ver\(([0-9.]+)\)"#, options: .regularExpression) as NSRange?,
           range.location != NSNotFound {
            let match = nsText.substring(with: range)
            mccsVersion = match.replacingOccurrences(of: #"mccs_ver\("#, with: "", options: .regularExpression)
                .replacingOccurrences(of: ")", with: "")
        }
        // The vcp group ends at the first ')' that is not part of a
        // single-level sub-value group: vcp(10 12(01 02) 60).
        if let range = nsText.range(of: #"vcp\((?:[0-9A-Fa-f ]|\([0-9A-Fa-f ]*\))*\)"#, options: .regularExpression) as NSRange?,
           range.location != NSNotFound {
            let match = nsText.substring(with: range)
            // Strip sub-values first ("10 12(01 02) 60)" -> "10 12  60)"),
            // then the group's own closing paren, then tokenize.
            let stripped = match
                .replacingOccurrences(of: #"vcp\("#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\([0-9A-Fa-f ]*\)"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: ")", with: " ")
            for token in stripped.split(separator: " ") {
                // VCP codes in the capabilities reply are hex (e.g. "8D" = mute).
                if let code = UInt8(token, radix: 16) { codes.insert(code) }
            }
        }
        return DDCCapabilities(mccsVersion: mccsVersion, vcpCodes: codes, raw: text)
    }

    /// Mute state from a VCP 0x8D read-back: MCCS defines 1 = muted (on), 2 = unmuted (off).
    public static func isMuted(_ raw: Double) -> Bool { raw <= 1.5 }

    /// A VCP 0x60 read-back as a source number, clamped.
    ///
    /// The DDC layer reports a feature value as a `Double`, and a monitor that answers with
    /// something out of range would trap a plain `UInt16(...)` cast — in a view, which is the
    /// worst place for a crash. Nil in, nil out.
    public static func inputSource(from value: Double?) -> UInt16? {
        guard let value, value.isFinite else { return nil }
        return UInt16(min(max(value, 0), Double(UInt16.max)))
    }

    /// Name for a well-known MCCS input-source value (VCP 0x60).
    ///
    /// The standard assigns these, but vendors disagree often enough that a fixed
    /// list is not safe to present on its own — which is why callers offer only
    /// the values the *display itself* reports (see `capabilityValues(for:in:)`),
    /// and fall back to the raw number for anything unnamed here.
    public static func inputSourceName(for value: UInt16) -> String? {
        switch value {
        case 0x01: return "Analog 1"
        case 0x02: return "Analog 2"
        case 0x03: return "Digital 1"
        case 0x04: return "Digital 2"
        case 0x05: return "Composite 1"
        case 0x06: return "Composite 2"
        case 0x07: return "S-Video 1"
        case 0x08: return "S-Video 2"
        case 0x09: return "Tuner 1"
        case 0x0A: return "Tuner 2"
        case 0x0B: return "Tuner 3"
        case 0x0C: return "Component 1"
        case 0x0D: return "Component 2"
        case 0x0E: return "Component 3"
        case 0x0F: return "DisplayPort 1"
        case 0x10: return "DisplayPort 2"
        case 0x11: return "HDMI 1"
        case 0x12: return "HDMI 2"
        default: return nil
        }
    }

    /// The values a display reports for one VCP code, from its capabilities text.
    ///
    /// The grammar encloses them in single-level parens after the code:
    /// `vcp(10 12 60(0F 10 11 12))`. An **empty** result means the display lists
    /// the code with no value set, which is common and means "supported, but we
    /// cannot know which inputs" — callers must not substitute a guess.
    ///
    /// The code must start its own token, so `60(` cannot match inside `160(`.
    public static func capabilityValues(for code: UInt8, in text: String) -> [UInt16] {
        let hex = String(format: "%02X", code)
        let pattern = "(?:^|[^0-9A-Fa-f])\(hex)\\(([0-9A-Fa-f ]*)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: whole),
              match.numberOfRanges > 1,
              let inner = Range(match.range(at: 1), in: text) else { return [] }

        // Preserve the display's own ordering, and drop duplicates.
        var seen = Set<UInt16>()
        var values: [UInt16] = []
        for token in text[inner].split(separator: " ") {
            guard let value = UInt16(token, radix: 16), seen.insert(value).inserted else { continue }
            values.append(value)
        }
        return values
    }

    /// The DDC panel's read-back values, gathered in one pass.
    ///
    /// A value type crossing a queue boundary, hence `Sendable`.
    public struct DDCState: Equatable, Sendable {
        public var contrast: Double?
        public var volume: Double?
        public var muted: Bool?
        /// The display's current input (VCP 0x60), when it answers — many monitors ignore this
        /// read, and some vendors disagree about what the numbers mean. Carried in the same batch
        /// as the rest so marking the current input costs no extra DDC traffic.
        public var inputSource: Double?

        public init(
            contrast: Double? = nil,
            volume: Double? = nil,
            muted: Bool? = nil,
            inputSource: Double? = nil
        ) {
            self.contrast = contrast
            self.volume = volume
            self.muted = muted
            self.inputSource = inputSource
        }
    }
}

/// High-level DDC controls FBD exposes, mapped to VCP codes.
public enum DDCFeature: CaseIterable {
    case brightness
    case contrast
    case volume
    case mute
    case inputSource

    public var vcpCode: UInt8 {
        switch self {
        case .brightness: return DDC.VCPCode.brightness.rawValue
        case .contrast: return DDC.VCPCode.contrast.rawValue
        case .volume: return DDC.VCPCode.speakerVolume.rawValue
        case .mute: return DDC.VCPCode.audioMute.rawValue
        case .inputSource: return DDC.VCPCode.inputSource.rawValue
        }
    }

    public var isContinuous: Bool {
        switch self {
        case .brightness, .contrast, .volume: return true
        case .mute, .inputSource: return false
        }
    }

    /// Display identity key used for persisted per-display feature availability.
    public var settingsKey: String {
        switch self {
        case .brightness: return "brightness"
        case .contrast: return "contrast"
        case .volume: return "volume"
        case .mute: return "mute"
        case .inputSource: return "inputSource"
        }
    }
}
