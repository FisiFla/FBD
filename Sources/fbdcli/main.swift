import FBDCLIParser
import FBDCore
import Foundation
import os

let log = Logger(subsystem: "dev.fisifla.fbd", category: "fbdcli")

// MARK: - Usage

/// Full usage text printed by `help` and on argument errors.
private let usageText = """
fbdcli — Free Better Display command-line interface

Usage: fbdcli <command> [args]

Commands:
  list [--json]                 List displays (one line per display, or JSON)
  info <id> [--json]            Show full detail for a display (or JSON)
  brightness <id> [0-100]       Get or set brightness (Apple or DDC path)
  contrast <id> [0-100]         Get or set contrast (DDC)
  volume <id> [0-100]           Get or set speaker volume (DDC)
  mute <id> [on|off]            Get or set mute state (DDC)
  input <id> [source]           Get current input source or switch (DDC)
  caps <id>                     Read and print DDC capabilities
  modes <id>                    List all modes for a display
  set-mode <id> <W>x<H>[@<hz>]  Apply a matching mode
  ddc-test <id>                 DDC diagnostics (arch, AVService, VCP reads)
  xdr <id> [nits|off]           Get or set XDR brightness upscaling (nits
                                target on XDR-capable displays)
  preset <id> [index]           List factory display presets (SDR/HDR nits,
                                * = active) or activate one by index
  hdr <id> [on|off]             Show or set HDR framebuffer mode (displays
                                that expose the mode)
  virtual list                  List persisted virtual screen configs
  virtual create <name> <W>x<H>[@<hz>] [--hdr] [--no-auto]
                                Create and connect a virtual screen
  virtual destroy <id-or-name>  Disconnect and forget a virtual screen
  virtual reconnect <id-or-name>
                                Reconnect a persisted virtual screen
  virtual disconnect-all        Disconnect all virtual screens (keep configs)
  disable <id>                  Disable a display (black screen until re-enabled)
  enable <id>                   Re-enable a disabled display
  layout save                   Save the current display arrangement
  layout restore                Restore the saved arrangement
  layout protect [on|off]       Get or set layout protection
  group list                    List display groups and their members
  group create <name> [id...]   Create a group (member ids optional)
  group delete <name>           Delete a group
  group add <name> <id>         Add a display to a group
  group remove <name> <id>      Remove a display from a group
  group mirror <name>           Mirror the group's displays
  group unmirror <name>         Unmirror the group's displays
  edid export <id> [file]       Export the display's EDID (hex dump + parsed
                                summary, or write the raw bytes to file)
  edid apply <id> <file|hex>    Apply an EDID override from a file or hex string
  edid restore <id>             Restore the factory EDID
  edid auto [on|off]            Get or set auto-apply of saved EDID overrides
  profile list <id>             List color profiles (index, name, url) + default
  profile apply <id> <index|url> Apply a color profile by list index or URL
  profile restore <id>          Restore the default color profile
  underscan <id> [on|off]       Get or set underscan (TVs; set only)
  protect config [on|off]       Get or set config protection
  protect save <id>             Save current resolution/preset/brightness
  protect restore <id>          Re-apply saved config if needed
  http on [port]                Enable the HTTP control API (port 1024-65535;
                                default keeps the current port). The API is
                                served by the app — applied live, no restart
  http off                      Disable the HTTP control API
  http status                   Show HTTP API state and port
  auth-token                    Print the local HTTP API token (needed for
                                curl and other HTTP clients)
  settings                      Print a masked settings dump (for bug reports)
  pip <id> [b] [c] [s]          Stream a display in a picture-in-picture window
                                (optional brightness/contrast/saturation, 1 =
                                none). Streams until the window closes or a
                                key is pressed
  pip stop                      Stop the active CLI PiP stream
  osd <icon> <0-100>            Show a transient OSD HUD (e.g. sun.max,
                                speaker.wave.2) at the given percentage
  nightshift [0-100]            Get or set Night Shift strength
  truetone [on|off]             Get or set True Tone
  tv <brand> <host> [action]    Control a TV/AVR over the network: brand is
                                lg, samsung, philips, or yamaha; action is
                                volume <0-100>, power, or input <name>
                                (requires the device in network/API mode)
  help                          Show this help

Exit codes: 0 success, 1 usage/argument error, 2 operation failed.
"""

// MARK: - Dispatch

/// Parse arguments and dispatch to the requested command.
@MainActor
func run(arguments: [String]) -> Int32 {
    // Parse and dispatch. Parsing lives in FBDCLI (unit-tested); dispatch
    // and command bodies stay here.
    switch CLICommandLine.parse(Array(arguments.dropFirst())) {
    case .usage:
        print(usageText)
        return 0
    case .help:
        print(usageText)
        return 0
    case .unknown(let rawCommand):
        print("fbdcli: unknown command '\(rawCommand)'\n")
        print(usageText)
        return 1
    case .command(let command, let args, let direct):
        // Route over the app's HTTP API when it is running (single-driver I2C).
        if !direct, HTTPRouting.routable.contains(command), !args.contains("--json") {
            if let exitCode = HTTPRouting.route(command, args: args) {
                return exitCode
            }
            print("fbdcli: app HTTP API not available — using direct controllers")
        }

        let controller = DisplayController.shared
        controller.start()
        let rest = Array(args.dropFirst())

    switch command {
    case .list:
        return cmdList(controller, args: rest)
    case .info:
        return withDisplay(controller, rest) { cmdInfo($0, args: $1) }
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
        guard let displayID = requireOnlineDisplay(rest.first) else { return 1 }
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
        return cmdAuthToken()
    case .settings:
        return cmdSettings()
    case .pip:
        return cmdPip(controller, args: rest)
    case .osd:
        return cmdOSD(args: rest)
    case .nightshift:
        return cmdNightShift(args: rest)
    case .truetone:
        return cmdTrueTone(args: rest)
    case .tv:
        return cmdTV(args: rest)
    case .help:
            print(usageText)
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
