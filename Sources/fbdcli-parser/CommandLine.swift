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
