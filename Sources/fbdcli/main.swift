import FBDCore
import Foundation
import os

// MARK: - Command surface

/// Commands accepted by fbdcli. Raw values match the CLI verbatim.
enum Command: String {
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
    case help
}

/// Standalone DDC probe used for read-only VCP/capabilities access that
/// DisplayController does not expose (contrast/volume/mute/input reads,
/// capabilities, ddc-test). Writes still go through DisplayController so the
/// app's routing (Apple vs DDC) stays authoritative.
let ddcProbe = DDCController(external: ExternalController())

let log = Logger(subsystem: "dev.fisifla.fbd", category: "fbdcli")

// MARK: - Usage

/// Full usage text printed by `help` and on argument errors.
private let usageText = """
fbdcli — Free Better Display command-line interface

Usage: fbdcli <command> [args]

Commands:
  list                          List displays (one line per display)
  info <id>                     Show full detail for a display
  brightness <id> [0-100]       Get or set brightness (Apple or DDC path)
  contrast <id> [0-100]         Get or set contrast (DDC)
  volume <id> [0-100]           Get or set speaker volume (DDC)
  mute <id> [on|off]            Get or set mute state (DDC)
  input <id> [source]           Get current input source or switch (DDC)
  caps <id>                     Read and print DDC capabilities
  modes <id>                    List all modes for a display
  set-mode <id> <W>x<H>[@<hz>]  Apply a matching mode
  ddc-test <id>                 DDC diagnostics (arch, AVService, VCP reads)
  help                          Show this help

Exit codes: 0 success, 1 usage/argument error, 2 operation failed.
"""

// MARK: - Dispatch

/// Parse arguments and dispatch to the requested command.
@MainActor
func run(arguments: [String]) -> Int32 {
    let args = Array(arguments.dropFirst())

    // No arguments / bare help → usage, success.
    guard let rawCommand = args.first else {
        print(usageText)
        return 0
    }
    guard let command = Command(rawValue: rawCommand) else {
        print("fbdcli: unknown command '\(rawCommand)'\n")
        print(usageText)
        return 1
    }
    if command == .help {
        print(usageText)
        return 0
    }

    let controller = DisplayController.shared
    controller.start()
    let rest = Array(args.dropFirst())

    switch command {
    case .list:
        return cmdList(controller)
    case .info:
        guard let display = requireDisplay(rest.first, in: controller) else { return 1 }
        return cmdInfo(display)
    case .brightness:
        guard let display = requireDisplay(rest.first, in: controller) else { return 1 }
        return cmdBrightness(controller, display: display, args: rest)
    case .contrast:
        guard let display = requireDisplay(rest.first, in: controller) else { return 1 }
        return cmdContrast(controller, display: display, args: rest)
    case .volume:
        guard let display = requireDisplay(rest.first, in: controller) else { return 1 }
        return cmdVolume(controller, display: display, args: rest)
    case .mute:
        guard let display = requireDisplay(rest.first, in: controller) else { return 1 }
        return cmdMute(controller, display: display, args: rest)
    case .input:
        guard let display = requireDisplay(rest.first, in: controller) else { return 1 }
        return cmdInput(controller, display: display, args: rest)
    case .caps:
        guard let display = requireDisplay(rest.first, in: controller) else { return 1 }
        return cmdCaps(display)
    case .modes:
        guard let display = requireDisplay(rest.first, in: controller) else { return 1 }
        return cmdModes(display)
    case .setMode:
        guard let display = requireDisplay(rest.first, in: controller) else { return 1 }
        return cmdSetMode(controller, display: display, args: rest)
    case .ddcTest:
        guard let display = requireDisplay(rest.first, in: controller) else { return 1 }
        return cmdDdcTest(display)
    case .help:
        print(usageText)
        return 0
    }
}

// MARK: - Shared helpers

/// Left-pad a string to `width` columns (never truncates).
func pad(_ string: String, _ width: Int) -> String {
    string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
}

func yesno(_ value: Bool) -> String { value ? "yes" : "no" }

/// Parse a display id: plain decimal, or 0x-prefixed hex.
func parseDisplayID(_ string: String) -> UInt32? {
    if string.hasPrefix("0x") || string.hasPrefix("0X") {
        return UInt32(string.dropFirst(2), radix: 16)
    }
    return UInt32(string)
}

/// Resolve a display by id. Prints a message and returns nil on failure
/// (caller exits 1: usage/argument error).
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
    let parts = spec.split(separator: "@", maxSplits: 1)
    let hz: Double?
    if parts.count > 1 {
        guard let parsed = Double(parts[1]), parsed > 0 else { return nil }
        hz = parsed
    } else {
        hz = nil
    }
    let dimensions = parts[0].split(separator: "x", maxSplits: 1)
    guard dimensions.count == 2,
          let width = Int32(dimensions[0]), width > 0,
          let height = Int32(dimensions[1]), height > 0 else {
        return nil
    }
    return (width, height, hz)
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
    if !display.ddcAvailable { return "no AVService found for display \(display.id)" }
    return nil
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
