import Foundation

/// Parsed `fbdcli hidpi <id> install|remove|status [--preview]`.
///
/// The smooth-scaling override is a file under /Library, so installing one
/// asks macOS for an administrator password. The parser only says which
/// operation was asked for — who runs the privileged step is the service's
/// business.
public struct HiDPIArgs: Equatable, Sendable {
    /// What the command does with the display's ladder.
    public enum Operation: String, Equatable, Sendable {
        /// Install the ladder (asks for an administrator password).
        case install
        /// Remove the ladder.
        case remove
        /// Report the state; nothing is changed.
        case status
    }

    /// The display the command is about.
    public let displayID: UInt32
    /// The operation that was asked for.
    public let operation: Operation
    /// Whether the ladder is printed first and nothing is changed.
    public let preview: Bool

    public init(displayID: UInt32, operation: Operation, preview: Bool = false) {
        self.displayID = displayID
        self.operation = operation
        self.preview = preview
    }

    /// Parse the words after `hidpi`.
    public static func parse(_ args: [String]) -> Result<HiDPIArgs, TVCommandValidation.Failure> {
        guard let first = args.first else {
            return .failure(TVCommandValidation.Failure("expected <id> install|remove|status"))
        }
        guard let displayID = UInt32(first) else {
            return .failure(TVCommandValidation.Failure("display id must be a number (got '\(first)')"))
        }
        guard args.count >= 2 else {
            return .failure(TVCommandValidation.Failure("expected install, remove or status"))
        }
        guard let operation = Operation(rawValue: args[1].lowercased()) else {
            return .failure(TVCommandValidation.Failure(
                "unknown operation '\(args[1])' (expected install, remove or status)"
            ))
        }
        var preview = false
        for flag in args.dropFirst(2) {
            guard flag == "--preview" else {
                return .failure(TVCommandValidation.Failure("unknown option '\(flag)' (expected --preview)"))
            }
            preview = true
        }
        return .success(HiDPIArgs(displayID: displayID, operation: operation, preview: preview))
    }
}

/// Parsed `fbdcli gamma-floor <id> [on|off] [value]`.
///
/// The bare form reports the blend's state and changes nothing; `on`/`off`
/// turns it on or off, and the optional value is the threshold in percent.
/// Without a value the configured threshold is kept.
public struct GammaFloorArgs: Equatable, Sendable {
    /// What the command does.
    public enum Action: Equatable, Sendable {
        /// Report the state; nothing is changed.
        case report
        /// Turn the blend on or off. The threshold is a percentage; nil keeps
        /// the threshold that is configured.
        case set(enabled: Bool, thresholdPercent: Double?)
    }

    /// The display the command is about.
    public let displayID: UInt32
    /// The action that was asked for.
    public let action: Action

    public init(displayID: UInt32, action: Action) {
        self.displayID = displayID
        self.action = action
    }

    /// Parse the words after `gamma-floor`.
    public static func parse(_ args: [String]) -> Result<GammaFloorArgs, TVCommandValidation.Failure> {
        guard let first = args.first else {
            return .failure(TVCommandValidation.Failure("expected <id> [on|off] [value]"))
        }
        guard let displayID = UInt32(first) else {
            return .failure(TVCommandValidation.Failure("display id must be a number (got '\(first)')"))
        }
        guard args.count >= 2 else {
            return .success(GammaFloorArgs(displayID: displayID, action: .report))
        }
        let enabled: Bool
        switch args[1].lowercased() {
        case "on": enabled = true
        case "off": enabled = false
        default:
            return .failure(TVCommandValidation.Failure("expected on or off (got '\(args[1])')"))
        }
        var threshold: Double?
        if args.count >= 3 {
            guard let value = Double(args[2]), value.isFinite, (0...100).contains(value) else {
                return .failure(TVCommandValidation.Failure(
                    "threshold must be a number between 0 and 100 (got '\(args[2])')"
                ))
            }
            threshold = value
        }
        guard args.count <= 3 else {
            return .failure(TVCommandValidation.Failure("too many arguments (expected <id> [on|off] [value])"))
        }
        return .success(GammaFloorArgs(
            displayID: displayID,
            action: .set(enabled: enabled, thresholdPercent: threshold)
        ))
    }
}

/// Parsed `fbdcli display <id> disconnect|reconnect [--remember]` and
/// `fbdcli display --list-remembered`.
///
/// `--remember` is the disconnect memory: the display stays off when it is
/// plugged back in.
public struct DisplayArgs: Equatable, Sendable {
    /// What the command does.
    public enum Action: Equatable, Sendable {
        /// Disconnect the display; the flag says whether it stays off when it
        /// comes back.
        case disconnect(remember: Bool)
        /// Reconnect the display (and forget the "keep it off" note).
        case reconnect
        /// List the displays FBD is remembering as off.
        case listRemembered
    }

    /// The display the command is about; nil for the listing.
    public let displayID: UInt32?
    /// The action that was asked for.
    public let action: Action

    public init(displayID: UInt32?, action: Action) {
        self.displayID = displayID
        self.action = action
    }

    /// Parse the words after `display`.
    public static func parse(_ args: [String]) -> Result<DisplayArgs, TVCommandValidation.Failure> {
        if args.contains("--list-remembered") {
            guard args.count == 1 else {
                return .failure(TVCommandValidation.Failure("'--list-remembered' takes no display id"))
            }
            return .success(DisplayArgs(displayID: nil, action: .listRemembered))
        }
        guard let first = args.first else {
            return .failure(TVCommandValidation.Failure(
                "expected <id> disconnect|reconnect or --list-remembered"
            ))
        }
        guard let displayID = UInt32(first) else {
            return .failure(TVCommandValidation.Failure("display id must be a number (got '\(first)')"))
        }
        guard args.count >= 2 else {
            return .failure(TVCommandValidation.Failure("expected disconnect or reconnect"))
        }
        let action: Action
        switch args[1].lowercased() {
        case "disconnect":
            var remember = false
            for flag in args.dropFirst(2) {
                guard flag == "--remember" else {
                    return .failure(TVCommandValidation.Failure("unknown option '\(flag)' (expected --remember)"))
                }
                remember = true
            }
            action = .disconnect(remember: remember)
        case "reconnect":
            guard args.count == 2 else {
                return .failure(TVCommandValidation.Failure("'reconnect' takes no further arguments"))
            }
            action = .reconnect
        default:
            return .failure(TVCommandValidation.Failure(
                "unknown action '\(args[1])' (expected disconnect or reconnect)"
            ))
        }
        return .success(DisplayArgs(displayID: displayID, action: action))
    }
}

/// The smooth-scaling override's state for one display, as plain values.
///
/// The CLI prints the same line whether it asked the app or read the state
/// itself, so the wording lives here — in the library, which carries no
/// FBDCore dependency.
public struct HiDPIOverrideStatus: Equatable, Sendable {
    /// Whether the display can carry a ladder at all.
    public let isSupported: Bool
    /// Whether the ladder is installed right now.
    public let isInstalled: Bool
    /// How many scaled modes the ladder holds.
    public let modeCount: Int
    /// Whether installing it would ask for an administrator password.
    public let wouldPrompt: Bool
    /// Where the override file lives.
    public let path: String

    public init(
        isSupported: Bool,
        isInstalled: Bool,
        modeCount: Int,
        wouldPrompt: Bool,
        path: String
    ) {
        self.isSupported = isSupported
        self.isInstalled = isInstalled
        self.modeCount = modeCount
        self.wouldPrompt = wouldPrompt
        self.path = path
    }

    /// The one-line summary of the state.
    public var summary: String {
        "supported=\(isSupported ? "yes" : "no")"
        + " installed=\(isInstalled ? "yes" : "no")"
        + " modes=\(modeCount)"
        + " adminPrompt=\(wouldPrompt ? "yes" : "no")"
    }
}

/// One scaled mode of the ladder, as plain values.
///
/// The preview prints the logical size (what the user sees) next to the
/// backing size (the pixels it is drawn into).
public struct ScaledModePreview: Equatable, Sendable {
    /// The size the user sees, in points.
    public let logicalWidth: Int
    public let logicalHeight: Int
    /// The size of the backing store, in pixels.
    public let backingWidth: Int
    public let backingHeight: Int

    public init(
        logicalWidth: Int,
        logicalHeight: Int,
        backingWidth: Int,
        backingHeight: Int
    ) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.backingWidth = backingWidth
        self.backingHeight = backingHeight
    }

    /// The line the preview prints for this mode.
    public var line: String {
        "\(logicalWidth)x\(logicalHeight) points  ->  \(backingWidth)x\(backingHeight) pixels"
    }
}

/// The below-floor brightness blend's state for one display.
///
/// The threshold is a fraction of the hardware scale, the way the blend
/// itself stores it; the CLI shows it as the percentage the user typed.
public struct FloorBlendStatus: Equatable, Sendable {
    /// Whether the blend is active.
    public let isEnabled: Bool
    /// The threshold as a fraction of the hardware scale (0…1).
    public let threshold: Double

    public init(isEnabled: Bool, threshold: Double) {
        self.isEnabled = isEnabled
        self.threshold = threshold
    }

    /// The one-line summary of the state.
    public var summary: String {
        "\(isEnabled ? "on" : "off") (threshold \(Int((threshold * 100).rounded()))%)"
    }
}
