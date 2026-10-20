import FBDCLIParser
import FBDCore
import Foundation
import os

let log = Logger(subsystem: "dev.fisifla.fbd", category: "fbdcli")

// MARK: - Usage

// MARK: - Dispatch

/// Parse arguments and dispatch to the requested command.
@MainActor
func run(arguments: [String]) -> Int32 {
    // Parse and dispatch. Parsing lives in FBDCLI (unit-tested); dispatch
    // and command bodies stay here.
    switch CLICommandLine.parse(Array(arguments.dropFirst())) {
    case .usage:
        print(UsageText.text)
        return 0
    case .help:
        print(UsageText.text)
        return 0
    case .unknown(let rawCommand):
        print("fbdcli: unknown command '\(rawCommand)'\n")
        print(UsageText.text)
        return 1
    case .command(let command, let args, let direct):
        let rest = Array(args.dropFirst())
        // Route over the app's HTTP API when it is running (single-driver I2C).
        // A few invocations have no HTTP route of their own and answer
        // locally: the JSON dumps, the ladder preview and the two reads the
        // app's API does not expose.
        let localOnly = CLICommandLine.wantsDirectJSON(command, raw: args)
            || CLICommandLine.wantsDirectPreview(command, raw: args)
        if !direct, !localOnly, HTTPRouting.canRoute(command, args: rest) {
            if let exitCode = HTTPRouting.route(command, args: args) {
                return exitCode
            }
            print("fbdcli: app HTTP API not available — using direct controllers")
        }

        // The agent skill is a file operation: it needs neither the app's
        // HTTP API nor the display controller, so it is dispatched before
        // anything is set up.
        if command == .skill {
            return cmdSkill(args: rest)
        }

        let controller = DisplayController.shared
        controller.start()

    switch command {
    case .list:
        return cmdList(controller, args: rest)
    case .info:
        return withDisplay(controller, rest) { cmdInfo($0, args: $1) }
    case .report:
        return cmdReport(controller, args: rest)
    case .brightness:
        return withDisplay(controller, rest) { cmdBrightness(controller, display: $0, args: $1) }
    case .contrast:
        return withDisplay(controller, rest) { cmdContrast(controller, display: $0, args: $1) }
    case .volume:
        return withDisplay(controller, rest) { cmdVolume(controller, display: $0, args: $1) }
    case .mute:
        return withDisplay(controller, rest) { cmdMute(controller, display: $0, args: $1) }
    case .input:
        return withDisplay(controller, rest) { cmdInput(controller, display: $0, args: $1) }
    case .caps:
        return withDisplay(controller, rest) { display, _ in cmdCaps(controller, display: display) }
    case .modes:
        return withDisplay(controller, rest) { display, _ in cmdModes(display) }
    case .setMode:
        return withDisplay(controller, rest) { cmdSetMode(controller, display: $0, args: $1) }
    case .ddcTest:
        return withDisplay(controller, rest) { display, _ in cmdDdcTest(controller, display: display) }
    case .xdr:
        return withDisplay(controller, rest) { cmdXDR(controller, display: $0, args: $1) }
    case .preset:
        return withDisplay(controller, rest) { cmdPreset(controller, display: $0, args: $1) }
    case .hdr:
        return withDisplay(controller, rest) { cmdHDR(controller, display: $0, args: $1) }
    case .virtual:
        return cmdVirtual(args: rest)
    case .rotate:
        return cmdRotate(controller, args: rest)
    case .filter:
        return cmdFilter(controller, args: rest)
    case .disable:
        guard let displayID = requireOnlineDisplay(rest.first) else { return 1 }
        return cmdDisableEnable(displayID: displayID, enabled: false)
    case .enable:
        // Deliberately NOT requireOnlineDisplay: bringing a display back is
        // exactly the case where it is offline. A soft-disabled *external*
        // display leaves the online list entirely on this OS, so requiring
        // online-ness here made `disable` a one-way trip with no way back from
        // the CLI.
        guard let rawID = rest.first, let displayID = requireDisplayID(rawID) else { return 1 }
        return cmdDisableEnable(displayID: displayID, enabled: true)
    case .layout:
        return cmdLayout(args: rest)
    case .group:
        return cmdGroup(controller, args: rest)
    case .edid:
        return cmdEDID(controller, args: rest)
    case .profile:
        return cmdProfile(controller, args: rest)
    case .underscan:
        return withDisplay(controller, rest) { cmdUnderscan(display: $0, args: $1) }
    case .protect:
        return cmdProtect(controller, args: rest)
    case .http:
        return cmdHTTP(args: rest)
    case .authToken:
        return cmdAuthToken(args: rest)
    case .settings:
        return cmdSettings()
    case .pip:
        return cmdPip(controller, args: rest)
    case .stream:
        return cmdStream(controller, args: rest)
    case .automation:
        return cmdAutomation(controller, args: rest)
    case .osd:
        return cmdOSD(args: rest)
    case .sysvolume:
        return cmdSysVolume(args: rest)
    case .nightshift:
        return cmdNightShift(args: rest)
    case .truetone:
        return cmdTrueTone(args: rest)
    case .darkMode:
        return cmdDarkMode(args: rest)
    case .dpcd:
        return withDisplay(controller, rest) { cmdDPCD(controller, display: $0, args: $1) }
    case .ambientLight:
        return withDisplay(controller, rest) { cmdAmbientLight(controller, display: $0, args: $1) }
    case .hidpi:
        return cmdHiDPI(controller, args: rest)
    case .gammaFloor:
        return cmdGammaFloor(controller, args: rest)
    case .display:
        return cmdDisplay(controller, args: rest)
    case .config:
        return cmdConfig(controller, args: rest)
    case .skill:
        // Dispatched above, before the display controller starts.
        return cmdSkill(args: rest)
    case .tv:
        return cmdTV(args: rest)
    case .help:
            print(UsageText.text)
            return 0
        }
    }
}

// MARK: - Shared helpers

/// Left-pad a string to `width` columns (never truncates).
func pad(_ string: String, _ width: Int) -> String {
    string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
}

func yesno(_ value: Bool) -> String { value ? "yes" : "no" }

/// The command that reads back the state a write changed, with the display id
/// filled in. nil when no command prints that state — the CLI then says so
/// rather than pointing at a command that cannot show it.
func readBackCommand(_ command: Command, _ id: String? = nil) -> String? {
    CLIGrammar.readBack(for: command, id: id)
}

/// Print the CLI's write-failure line and return the exit code.
///
/// The wording is the CLI's contract for an unconfirmed write: it says what
/// happened and names the command that reads the state back. It never invites
/// a blind retry — a write that may have landed must be checked, not repeated.
@discardableResult
func reportWriteFailure(outcome: WriteOutcome, command: String, readBack: String?) -> Int32 {
    let failure = WriteFailure(outcome: outcome, command: command, readBack: readBack)
    print(failure.message)
    return failure.exitCode
}

/// Parse a display id: plain decimal, or 0x-prefixed hex.
func parseDisplayID(_ string: String) -> UInt32? {
    if string.hasPrefix("0x") || string.hasPrefix("0X") {
        return UInt32(string.dropFirst(2), radix: 16)
    }
    return UInt32(string)
}

/// Resolves the display-id argument and runs `body`, or prints the standard
/// CLI error and fails. Collapses the guard-and-fail shape repeated at every
/// display command's dispatch.
@MainActor
func withDisplay(
    _ controller: DisplayController,
    _ rest: [String],
    _ body: (Display, [String]) -> Int32
) -> Int32 {
    guard let display = requireDisplay(rest.first, in: controller) else { return 1 }
    return body(display, rest)
}

/// Parses a display id, printing the CLI's standard error on failure.
func requireDisplayID(_ raw: String) -> UInt32? {
    guard let id = parseDisplayID(raw) else {
        print("fbdcli: invalid display id '\(raw)'")
        return nil
    }
    return id
}

/// Ensures `args` has at least `count` elements, printing `usage` otherwise.
@discardableResult
func requireArgCount(_ args: [String], _ count: Int, usage: String) -> Bool {
    guard args.count >= count else {
        print(usage)
        return false
    }
    return true
}

@MainActor
func requireDisplay(_ idString: String?, in controller: DisplayController) -> Display? {
    guard let idString, !idString.isEmpty else {
        print("fbdcli: missing display id")
        return nil
    }
    guard let id = parseDisplayID(idString) else {
        print("fbdcli: invalid display id '\(idString)'")
        return nil
    }
    guard let display = controller.display(withID: id) else {
        print("Display \(id) not found")
        return nil
    }
    return display
}

/// Parse a 0…100 percentage (brightness/contrast/volume). Prints a message and
/// returns nil on bad input (caller exits 1).
func parsePercent(_ string: String, command: String) -> Double? {
    guard let value = Double(string), value >= 0, value <= 100 else {
        print("fbdcli: \(command): value must be a number between 0 and 100 (got '\(string)')")
        return nil
    }
    return value
}

/// Parse "WxH[@hz]" for set-mode, e.g. "1920x1080" or "1920x1080@59.95".
func parseModeSpec(_ spec: String) -> (width: Int32, height: Int32, hz: Double?)? {
    guard let parsed = ModeSpec.parse(spec) else { return nil }
    return (parsed.width, parsed.height, parsed.hz)
}

// MARK: - DDC helpers

/// Message explaining why DDC is unavailable process-wide, or nil when running
/// natively on Apple Silicon. Note: `IOAVServiceAPI.isAppleSilicon` is false
/// under Rosetta by definition, so the Rosetta flag is the discriminator.
func ddcUnavailableMessage() -> String? {
    if IOAVServiceAPI.isRunningUnderRosetta {
        return "DDC requires native arm64 (not Rosetta)."
    }
    if !IOAVServiceAPI.isAppleSilicon {
        return "DDC is only available on Apple Silicon."
    }
    return nil
}

/// Reason DDC should not be attempted for this display, or nil if it looks usable.
func ddcFailureReason(for display: Display) -> String? {
    if let message = ddcUnavailableMessage() { return message }
    if !display.ddcAvailable {
        return hasAVService(display)
            ? "display \(display.id) does not answer DDC/CI (many TVs and some monitors don't support it)"
            : "no AVService found for display \(display.id)"
    }
    return nil
}

/// Whether the display has an IOAVService (the I2C transport), independent of DDC/CI replies.
func hasAVService(_ display: Display) -> Bool {
    IOAVServiceAPI.findAVService(displayID: display.id, vendor: display.vendorNumber,
                                 model: display.modelNumber, serial: display.serialNumber) != nil
}

/// Print a DDC-unavailable message when DDC cannot be used for `display`.
/// Returns true when the operation should be aborted.
func ddcUnusable(_ display: Display) -> Bool {
    if let reason = ddcFailureReason(for: display) {
        print("DDC unavailable for display \(display.id): \(reason)")
        return true
    }
    return false
}

// MARK: - Entry point

/// Main entry: assume the main actor (top-level code runs on the main thread)
/// and run the parsed command. `exit` never returns, so this must be the last
/// statement in the file — anything after it would be unreachable.
func runMain() -> Never {
    let exitCode = MainActor.assumeIsolated { run(arguments: CommandLine.arguments) }
    exit(exitCode)
}

runMain()
