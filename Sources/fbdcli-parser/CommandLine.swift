import FBDCore
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
    case stream
    case automation
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

/// Parsed `filter` arguments: the four positional colour values plus the
/// optional sharpening / geometry / LUT flags.
///
/// Deliberately produces plain values instead of `ScreenFilterParams` so this
/// library keeps its FBDCore-free dependency graph — `ScreenFilterParams`'s
/// initialiser remains the single source of truth for the numeric ranges, and
/// clamps whatever arrives here.
public struct ScreenFilterArgs: Equatable, Sendable {
    public var contrast: Double
    public var saturation: Double
    public var gamma: Double
    public var temperature: Double
    public var invert: Bool
    public var sharpness: Double?
    public var unsharpRadius: Double?
    public var zoom: Double?
    public var offsetX: Double?
    public var offsetY: Double?
    public var lutPath: String?

    public init(
        contrast: Double,
        saturation: Double,
        gamma: Double,
        temperature: Double,
        invert: Bool = false,
        sharpness: Double? = nil,
        unsharpRadius: Double? = nil,
        zoom: Double? = nil,
        offsetX: Double? = nil,
        offsetY: Double? = nil,
        lutPath: String? = nil
    ) {
        self.contrast = contrast
        self.saturation = saturation
        self.gamma = gamma
        self.temperature = temperature
        self.invert = invert
        self.sharpness = sharpness
        self.unsharpRadius = unsharpRadius
        self.zoom = zoom
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.lutPath = lutPath
    }

    /// Body for `POST /api/displays/<id>/filter`. Only the values the caller
    /// actually supplied are sent, so an omitted flag never overwrites a
    /// default with a stale one.
    public var payload: [String: Any] {
        var payload: [String: Any] = [
            "contrast": contrast,
            "saturation": saturation,
            "gamma": gamma,
            "temperature": temperature,
        ]
        if invert { payload["invert"] = true }
        if let sharpness { payload["sharpness"] = sharpness }
        if let unsharpRadius { payload["unsharpRadius"] = unsharpRadius }
        if let zoom { payload["zoom"] = zoom }
        if let offsetX { payload["offsetX"] = offsetX }
        if let offsetY { payload["offsetY"] = offsetY }
        if let lutPath { payload["lutPath"] = lutPath }
        return payload
    }

    /// Parse the arguments that follow the display id.
    ///
    ///        <contrast> <saturation> <gamma> <temperature>
    ///        [--invert] [--sharpness n] [--radius px] [--zoom n]
    ///        [--pan x y] [--lut path.cube]
    public static func parse(_ args: [String]) -> Result<ScreenFilterArgs, TVCommandValidation.Failure> {
        guard args.count >= 4 else {
            return .failure(TVCommandValidation.Failure(
                "expected <contrast> <saturation> <gamma> <temperature> [--invert] [--sharpness n] [--radius px] [--zoom n] [--pan x y] [--lut path.cube]"
            ))
        }
        guard let contrast = number(args[0]),
              let saturation = number(args[1]),
              let gamma = number(args[2]),
              let temperature = number(args[3]) else {
            return .failure(TVCommandValidation.Failure("filter values must be non-negative numbers"))
        }

        var parsed = ScreenFilterArgs(
            contrast: contrast, saturation: saturation, gamma: gamma, temperature: temperature
        )
        var index = 4
        while index < args.count {
            let flag = args[index]
            switch flag {
            case "--invert":
                parsed.invert = true
                index += 1

            case "--sharpness", "--radius", "--zoom":
                guard let raw = token(args, at: index + 1), let value = number(raw) else {
                    return .failure(TVCommandValidation.Failure("\(flag) expects a non-negative number"))
                }
                // Zooming out would drag the clamp-to-edge sampler into view.
                if flag == "--zoom", value < 1 {
                    return .failure(TVCommandValidation.Failure("--zoom must be at least 1 (zooming out would show smeared borders)"))
                }
                switch flag {
                case "--sharpness": parsed.sharpness = value
                case "--radius": parsed.unsharpRadius = value
                default: parsed.zoom = value
                }
                index += 2

            case "--pan":
                guard let rawX = token(args, at: index + 1), let rawY = token(args, at: index + 2),
                      let x = Double(rawX), let y = Double(rawY), x.isFinite, y.isFinite else {
                    return .failure(TVCommandValidation.Failure("--pan expects <x> <y> numbers"))
                }
                parsed.offsetX = x
                parsed.offsetY = y
                index += 3

            case "--lut":
                guard let path = token(args, at: index + 1), !path.isEmpty else {
                    return .failure(TVCommandValidation.Failure("--lut expects a path to a .cube file"))
                }
                parsed.lutPath = path
                index += 2

            default:
                return .failure(TVCommandValidation.Failure("unknown filter option '\(flag)'"))
            }
        }
        return .success(parsed)
    }

    private static func token(_ args: [String], at index: Int) -> String? {
        index < args.count ? args[index] : nil
    }

    private static func number(_ raw: String) -> Double? {
        guard let value = Double(raw), value.isFinite, value >= 0 else { return nil }
        return value
    }
}

/// Where a PiP stream gets its pixels, as plain values — this library stays
/// free of an FBDCore dependency, and the CLI maps these onto
/// `PiPCaptureSource`.
public enum PiPSourceArgs: Equatable, Sendable {
    case display(UInt32)
    case window(UInt32)
    case application(String)
}

/// Parsed `pip` arguments.
/// Options shared by `pip` and `stream` that are not filter values (#14).
public struct StreamOptions: Equatable, Sendable {
    /// Requested capture rate; nil leaves the stream at `StreamFrameRate.default`.
    public var fps: Int?
    /// Ask for the pointer to be kept off the stream's display. Honoured only
    /// when the experimental setting allows it.
    public var containCursor: Bool

    public init(fps: Int? = nil, containCursor: Bool = false) {
        self.fps = fps
        self.containCursor = containCursor
    }

    /// Strip `--fps <n>` and `--contain-cursor` out of a positional argument
    /// list, returning them alongside whatever remains for `VideoFilterArgs`.
    ///
    /// An out-of-range rate is a **failure, not a clamp**: a typo should be
    /// reported rather than silently become some other frame rate.
    public static func extract(
        _ args: [String]
    ) -> Result<(options: StreamOptions, rest: [String]), TVCommandValidation.Failure> {
        var options = StreamOptions()
        var rest: [String] = []
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--fps":
                guard index + 1 < args.count, let fps = Int(args[index + 1]) else {
                    return .failure(TVCommandValidation.Failure("--fps expects a whole number of frames per second"))
                }
                guard StreamFrameRate.range.contains(fps) else {
                    return .failure(TVCommandValidation.Failure(
                        "--fps must be \(StreamFrameRate.range.lowerBound)...\(StreamFrameRate.range.upperBound) (got \(fps))"
                    ))
                }
                options.fps = fps
                index += 2
            case "--contain-cursor":
                options.containCursor = true
                index += 1
            default:
                rest.append(args[index])
                index += 1
            }
        }
        return .success((options, rest))
    }
}

public struct PiPArgs: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case list
        case stop
        case start
    }

    public var action: Action
    public var source: PiPSourceArgs?
    /// brightness, contrast, saturation — 1 = no adjustment.
    public var filter: [Double]
    /// Requested capture rate; nil leaves the stream at `StreamFrameRate.default`.
    public var fps: Int?
    /// Ask for the pointer to be kept off the captured display.
    public var containCursor: Bool

    public init(
        action: Action,
        source: PiPSourceArgs? = nil,
        filter: [Double] = [1, 1, 1],
        fps: Int? = nil,
        containCursor: Bool = false
    ) {
        self.action = action
        self.source = source
        self.filter = filter
        self.fps = fps
        self.containCursor = containCursor
    }

    /// Parse `pip` arguments:
    ///
    ///     list | stop
    ///     <display-id>  [brightness] [contrast] [saturation] [--fps N] [--contain-cursor]
    ///     --window <id> [brightness] [contrast] [saturation] [--fps N]
    ///     --app <bundle-id> [brightness] [contrast] [saturation] [--fps N]
    ///
    /// The filter tail reuses `VideoFilterArgs`, so the one parser keeps
    /// covering both the display form and the new source forms.
    public static func parse(_ args: [String]) -> Result<PiPArgs, TVCommandValidation.Failure> {
        guard let first = args.first else {
            return .failure(TVCommandValidation.Failure(
                "expected <display-id>, --window <id>, --app <bundle-id>, list or stop"
            ))
        }
        if first == "list" || first == "stop" {
            guard args.count == 1 else {
                return .failure(TVCommandValidation.Failure("'\(first)' takes no further arguments"))
            }
            return .success(PiPArgs(action: first == "list" ? .list : .stop))
        }

        let source: PiPSourceArgs
        let filterArgs: [String]
        switch first {
        case "--window", "--app":
            guard args.count >= 2 else {
                return .failure(TVCommandValidation.Failure("\(first) expects an identifier"))
            }
            let identifier = args[1]
            guard !identifier.isEmpty else {
                return .failure(TVCommandValidation.Failure("\(first) expects a non-empty identifier"))
            }
            if first == "--window" {
                guard let windowID = UInt32(identifier) else {
                    return .failure(TVCommandValidation.Failure("--window expects a numeric window id (got '\(identifier)')"))
                }
                source = .window(windowID)
            } else {
                source = .application(identifier)
            }
            filterArgs = Array(args.dropFirst(2))

        default:
            guard let displayID = UInt32(first) else {
                return .failure(TVCommandValidation.Failure(
                    "expected a numeric display id or --window/--app (got '\(first)')"
                ))
            }
            source = .display(displayID)
            filterArgs = Array(args.dropFirst())
        }

        switch StreamOptions.extract(filterArgs) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let extracted):
            switch VideoFilterArgs.parse(extracted.rest) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let values):
                return .success(PiPArgs(
                    action: .start,
                    source: source,
                    filter: values,
                    fps: extracted.options.fps,
                    containCursor: extracted.options.containCursor
                ))
            }
        }
    }
}

/// Parsed `stream` arguments — **local streaming**: redirecting one display's
/// contents onto another display, full-screen.
public struct StreamArgs: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case stop
        case start
    }

    public var action: Action
    public var sourceDisplayID: UInt32?
    public var targetDisplayID: UInt32?
    /// brightness, contrast, saturation — 1 = no adjustment.
    public var filter: [Double]
    /// Requested capture rate; nil leaves the stream at `StreamFrameRate.default`.
    public var fps: Int?
    /// Ask for the pointer to be kept off the target display (experimental).
    public var containCursor: Bool

    public init(
        action: Action,
        sourceDisplayID: UInt32? = nil,
        targetDisplayID: UInt32? = nil,
        filter: [Double] = [1, 1, 1],
        fps: Int? = nil,
        containCursor: Bool = false
    ) {
        self.action = action
        self.sourceDisplayID = sourceDisplayID
        self.targetDisplayID = targetDisplayID
        self.filter = filter
        self.fps = fps
        self.containCursor = containCursor
    }

    /// Parse `stream` arguments:
    ///
    ///     stop
    ///     <source-display-id> <target-display-id> [brightness] [contrast] [saturation] [--fps N] [--contain-cursor]
    ///
    /// Rejecting source == target up front, because redirecting a display onto
    /// itself captures the stream's own window and would feed back forever.
    public static func parse(_ args: [String]) -> Result<StreamArgs, TVCommandValidation.Failure> {
        guard let first = args.first else {
            return .failure(TVCommandValidation.Failure(
                "expected <source-display-id> <target-display-id> or stop"
            ))
        }
        if first == "stop" {
            guard args.count == 1 else {
                return .failure(TVCommandValidation.Failure("'stop' takes no further arguments"))
            }
            return .success(StreamArgs(action: .stop))
        }
        guard args.count >= 2 else {
            return .failure(TVCommandValidation.Failure(
                "expected <source-display-id> <target-display-id> [brightness] [contrast] [saturation]"
            ))
        }
        guard let sourceID = UInt32(args[0]) else {
            return .failure(TVCommandValidation.Failure("source must be a numeric display id (got '\(args[0])')"))
        }
        guard let targetID = UInt32(args[1]) else {
            return .failure(TVCommandValidation.Failure("target must be a numeric display id (got '\(args[1])')"))
        }
        guard sourceID != targetID else {
            return .failure(TVCommandValidation.Failure("source and target must be different displays"))
        }
        switch StreamOptions.extract(Array(args.dropFirst(2))) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let extracted):
            switch VideoFilterArgs.parse(extracted.rest) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let values):
                return .success(StreamArgs(
                    action: .start,
                    sourceDisplayID: sourceID,
                    targetDisplayID: targetID,
                    filter: values,
                    fps: extracted.options.fps,
                    containCursor: extracted.options.containCursor
                ))
            }
        }
    }
}
