import Foundation

/// The fbdcli command vocabulary, shared between the executable and the
/// parser. Raw values match the CLI verbatim. Lives in a library target so
/// parsing is unit-testable (SwiftPM test targets cannot import executable
/// targets).
public enum Command: String, CaseIterable {
    case list
    case info
    case brightness
    case contrast
    case volume
    case mute
    case input
    case caps
    case modes
    case setMode = "set-mode"
    case ddcTest = "ddc-test"
    case xdr
    case preset
    case hdr
    case virtual
    case rotate
    case filter
    case disable
    case enable
    case layout
    case group
    case edid
    case profile
    case underscan
    case protect
    case http
    case authToken = "auth-token"
    case settings
    case pip
    case osd
    case nightshift
    case truetone
    case tv
    case help
}

/// Result of `CLICommandLine.parse`.
public enum ParseResult: Equatable {
    /// No arguments left after stripping `--direct` (bare invocation).
    case usage
    /// The `help` command.
    case help
    /// An unrecognized command word (carried for the error message).
    case unknown(String)
    /// A recognized command with the remaining arguments (including the
    /// command word itself, mirroring the historical CLI semantics).
    case command(Command, raw: [String], direct: Bool)
}

/// Pure argument parsing for fbdcli.
public enum CLICommandLine {
    /// Parse raw CLI arguments (already dropped from the process name).
    /// `--direct` may appear anywhere and is stripped before matching.
    public static func parse(_ arguments: [String]) -> ParseResult {
        var args = arguments
        let direct = args.contains("--direct")
        args.removeAll { $0 == "--direct" }
        guard let raw = args.first else { return .usage }
        if raw == "help" { return .help }
        guard let command = Command(rawValue: raw) else { return .unknown(raw) }
        return .command(command, raw: args, direct: direct)
    }
}

/// Validated `fbdcli tv` command (pure parsing, no controller access).
public struct TVCommand: Equatable {
    public enum Brand: String, CaseIterable {
        case lg, samsung, philips, yamaha
    }

    public enum Action: Equatable {
        case power
        case volume(Int)
        case input(String)
    }

    public let brand: Brand
    public let host: String
    public let action: Action
}

/// Argument validation for `fbdcli tv <brand> <host> [volume <0-100>|power|input <name>]`.
/// Extracted so the CLI's largest free-form validator is unit-tested.
public enum TVCommandValidation {
    public struct Failure: Error, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    public static func parse(_ args: [String]) -> Result<TVCommand, Failure> {
        guard args.count >= 2 else {
            return .failure(Failure("expected <lg|samsung|philips|yamaha> <host> [volume <0-100>|power|input <name>]"))
        }
        // Brands are matched case-insensitively ("LG", "Samsung" work).
        guard let brand = TVCommand.Brand(rawValue: args[0].lowercased()) else {
            return .failure(Failure("unknown brand '\(args[0])' (expected lg, samsung, philips, or yamaha)"))
        }
        let host = args[1]
        var actionWord = "power"
        var value = ""
        if args.count >= 3 {
            actionWord = args[2].lowercased()
            if args.count >= 4 { value = args[3] }
        }
        switch actionWord {
        case "power":
            return .success(TVCommand(brand: brand, host: host, action: .power))
        case "volume":
            guard let level = Int(value), (0...100).contains(level) else {
                return .failure(Failure("volume: expected a number between 0 and 100 (got '\(value)')"))
            }
            return .success(TVCommand(brand: brand, host: host, action: .volume(level)))
        case "input":
            guard !value.isEmpty else {
                return .failure(Failure("input: expected an input name (e.g. 'HDMI1', 'HDMI 1', 'WatchTV')"))
            }
            return .success(TVCommand(brand: brand, host: host, action: .input(value)))
        default:
            return .failure(Failure("unknown action '\(actionWord)' (expected volume, power, or input)"))
        }
    }
}

/// Parsed `WxH[@Hz]` display-mode spec (used by `set-mode` and
/// `virtual create`). Width/height must be positive; the refresh rate is
/// optional and must be positive when present.
public struct ModeSpec: Equatable {
    public let width: Int32
    public let height: Int32
    public let hz: Double?

    public static func parse(_ spec: String) -> ModeSpec? {
        // omittingEmptySubsequences: false so "1920x1080@" and "1920x"
        // are rejected instead of silently dropping the trailing part.
        let parts = spec.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let hz: Double?
        if parts.count > 1 {
            guard let parsed = Double(parts[1]), parsed > 0 else { return nil }
            hz = parsed
        } else {
            hz = nil
        }
        let dimensions = parts[0].split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false)
        guard dimensions.count == 2,
              let width = Int32(dimensions[0]), width > 0,
              let height = Int32(dimensions[1]), height > 0 else {
            return nil
        }
        return ModeSpec(width: width, height: height, hz: hz)
    }
}

/// Strict hex-string parsing for `edid apply` (whitespace tolerated, even
/// length required, hex digits only).
public enum EDIDHex {
    public static func parse(_ string: String) -> Data? {
        let cleaned = string.filter { !$0.isWhitespace }
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// 16-bytes-per-line hex dump ("%04X: xx xx ...") as used by
    /// `fbdcli edid export`.
    public static func dump(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 16 + 1)
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            lines.append(String(format: "%04X: %@", UInt32(offset), hex))
            offset += 16
        }
        return lines.joined(separator: "\n")
    }
}

/// Parsed `pip <id> [brightness] [contrast] [saturation]` filter arguments
/// (each a non-negative Double; default 1.0 = no adjustment).
public enum VideoFilterArgs {
    public static func parse(_ args: [String]) -> Result<[Double], TVCommandValidation.Failure> {
        guard args.count <= 3 else {
            return .failure(TVCommandValidation.Failure("too many arguments (expected [brightness] [contrast] [saturation])"))
        }
        var values = [1.0, 1.0, 1.0]
        for (index, string) in args.enumerated() {
            guard let value = Double(string), value >= 0 else {
                return .failure(TVCommandValidation.Failure("filter values must be non-negative numbers (got '\(string)')"))
            }
            values[index] = value
        }
        return .success(values)
    }
}
