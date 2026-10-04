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

    /// DDC/CI checksum: makes the byte sum of the message (incl. checksum) ≡ 0 mod 256.
    public static func checksum(_ bytes: [UInt8]) -> UInt8 {
        let sum = bytes.reduce(0) { ($0 + Int($1)) & 0xFF }
        return UInt8((0x100 - sum) & 0xFF)
    }

    // MARK: VCP write

    /// [0x51, 0x6C, code, hi, lo, checksum] — framed "set VCP feature" packet.
    /// The source address + checksum framing is what strict monitors expect
    /// (ddcutil uses the same); tolerant monitors accept it either way.
    public static func writeVCPPacket(code: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [sourceAddress, 0x6C, code, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return body + [checksum(body)]
    }

    // MARK: VCP read

    /// [0x51, 0x6D, code, checksum] — framed "get VCP feature" request packet.
    public static func readVCPRequest(code: UInt8) -> [UInt8] {
        let body: [UInt8] = [sourceAddress, 0x6D, code]
        return body + [checksum(body)]
    }

    /// Parse an 8-byte VCP reply: [0x6E, code, type, maxHi, maxLo, curHi, curLo, checksum].
    /// Tolerances: first byte may be 0x6D (some displays echo the request opcode);
    /// last byte may be a legacy 0x6F terminator instead of a checksum.
    public static func parseVCPReply(_ data: Data) -> (code: UInt8, value: DDCValue)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        guard bytes[0] == 0x6E || bytes[0] == 0x6D else { return nil }
        guard bytes[7] == 0x6F || bytes[7] == checksum(Array(bytes.prefix(7))) else { return nil }
        let code = bytes[1]
        let maxValue = UInt16(bytes[3]) << 8 | UInt16(bytes[4])
        let currentValue = UInt16(bytes[5]) << 8 | UInt16(bytes[6])
        return (code, DDCValue(maxValue: maxValue, currentValue: currentValue))
    }

    // MARK: Capabilities

    /// [0x51, 0x6F, 0xF3, checksum] — capabilities request packet.
    public static var capabilitiesRequest: [UInt8] {
        let body: [UInt8] = [sourceAddress, 0x6F, VCPCode.capabilities.rawValue]
        return body + [checksum(body)]
    }

    /// Extract the ASCII capabilities text from a capabilities reply.
    /// Reply layout: [0x6E|0x6F, 0xF3, lenHi, lenLo, 0x00, <ASCII caps…>, checksum|0x6F].
    public static func parseCapabilitiesText(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count > 6, bytes[0] == 0x6F || bytes[0] == 0x6E, bytes[1] == 0xF3 else { return nil }
        // Strip the trailing terminator (checksum or legacy 0x6F) if present.
        var end = bytes.count
        if end > 5 {
            let trailing = bytes[end - 1]
            if trailing == 0x6F || trailing == checksum(Array(bytes.prefix(end - 1))) { end -= 1 }
        }
        guard end > 5 else { return nil }
        let text = String(decoding: data[data.startIndex + 5 ..< data.startIndex + end], as: UTF8.self)
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
