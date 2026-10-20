import Foundation

/// One row of the CLI's grammar: how a command is invoked, what it does,
/// whether it changes state, and how that state is read back.
///
/// This table is the single source for two things that must not drift apart:
/// the grammar table in the agent skill (`AgentSkill`), and the "verify with"
/// hint the CLI prints when a write cannot be confirmed.
public struct CommandGrammar: Equatable {
    /// The command this row describes.
    public let command: Command
    /// The invocation, without the `fbdcli` prefix.
    public let usage: String
    /// One line of plain description.
    public let summary: String
    /// True when the command changes state — and therefore needs a read-back.
    public let mutating: Bool
    /// The command that reads the state back. `<id>` stands for the display
    /// id the command was given; nil when no command prints that state.
    public let readBack: String?

    public init(
        command: Command,
        usage: String,
        summary: String,
        mutating: Bool,
        readBack: String? = nil
    ) {
        self.command = command
        self.usage = usage
        self.summary = summary
        self.mutating = mutating
        self.readBack = readBack
    }
}

/// The fbdcli grammar, one row per command.
///
/// Written by hand rather than generated from the help text: the skill needs
/// a *table*, the help needs a *listing*, and the two read differently. The
/// rows are checked against the help text and against the command vocabulary
/// by the parser tests, so neither can fall behind.
public enum CLIGrammar {
    /// Every command, in the order `fbdcli help` lists them.
    public static let rows: [CommandGrammar] = [
        CommandGrammar(
            command: .list,
            usage: "list [--json]",
            summary: "List displays (one line per display, or JSON).",
            mutating: false
        ),
        CommandGrammar(
            command: .info,
            usage: "info <id> [--json]",
            summary: "Show the full detail of one display.",
            mutating: false
        ),
        CommandGrammar(
            command: .report,
            usage: "report [file]",
            summary: "Detailed report of every display, for a bug report.",
            mutating: false
        ),
        CommandGrammar(
            command: .brightness,
            usage: "brightness <id> [0-100]",
            summary: "Get or set brightness (Apple or DDC path).",
            mutating: true,
            readBack: "fbdcli brightness <id>"
        ),
        CommandGrammar(
            command: .contrast,
            usage: "contrast <id> [0-100]",
            summary: "Get or set contrast (DDC).",
            mutating: true,
            readBack: "fbdcli contrast <id>"
        ),
        CommandGrammar(
            command: .volume,
            usage: "volume <id> [0-100]",
            summary: "Get or set the display's speaker volume (DDC).",
            mutating: true,
            readBack: "fbdcli volume <id>"
        ),
        CommandGrammar(
            command: .mute,
            usage: "mute <id> [on|off]",
            summary: "Get or set the mute state (DDC).",
            mutating: true,
            readBack: "fbdcli mute <id>"
        ),
        CommandGrammar(
            command: .input,
            usage: "input <id> [source]",
            summary: "Get the current input source, or switch to one (DDC).",
            mutating: true,
            readBack: "fbdcli input <id>"
        ),
        CommandGrammar(
            command: .caps,
            usage: "caps <id>",
            summary: "Read and print the DDC capabilities of a display.",
            mutating: false
        ),
        CommandGrammar(
            command: .modes,
            usage: "modes <id>",
            summary: "List every mode a display offers (the current one is marked).",
            mutating: false
        ),
        CommandGrammar(
            command: .setMode,
            usage: "set-mode <id> <W>x<H>[@<hz>]",
            summary: "Apply the mode that best matches the requested one.",
            mutating: true,
            readBack: "fbdcli modes <id>"
        ),
        CommandGrammar(
            command: .ddcTest,
            usage: "ddc-test <id>",
            summary: "DDC diagnostics (architecture, AVService, VCP reads).",
            mutating: false
        ),
        CommandGrammar(
            command: .xdr,
            usage: "xdr <id> [nits|off]",
            summary: "Get or set XDR brightness upscaling (nits target).",
            mutating: true,
            readBack: "fbdcli xdr <id>"
        ),
        CommandGrammar(
            command: .preset,
            usage: "preset <id> [index]",
            summary: "List the factory presets, or activate one by index.",
            mutating: true,
            readBack: "fbdcli preset <id>"
        ),
        CommandGrammar(
            command: .hdr,
            usage: "hdr <id> [on|off]",
            summary: "Show or set the HDR framebuffer mode.",
            mutating: true,
            readBack: "fbdcli hdr <id>"
        ),
        CommandGrammar(
            command: .virtual,
            usage: "virtual list|create|destroy|reconnect|disconnect-all",
            summary: "Virtual screens: list, create, destroy, reconnect.",
            mutating: true,
            readBack: "fbdcli virtual list"
        ),
        CommandGrammar(
            command: .rotate,
            usage: "rotate <id> <0|90|180|270>",
            summary: "Rotate a display.",
            mutating: true,
            readBack: "fbdcli info <id>"
        ),
        CommandGrammar(
            command: .filter,
            usage: "filter <id> [off | <contrast> <saturation> <gamma> <temperature>]",
            summary: "Apply a full-screen software filter (needs Screen Recording).",
            mutating: true,
            readBack: "fbdcli info <id>"
        ),
        CommandGrammar(
            command: .disable,
            usage: "disable <id>",
            summary: "Disable a display (black screen until it is re-enabled).",
            mutating: true,
            readBack: "fbdcli list"
        ),
        CommandGrammar(
            command: .enable,
            usage: "enable <id>",
            summary: "Re-enable a disabled display.",
            mutating: true,
            readBack: "fbdcli list"
        ),
        CommandGrammar(
            command: .layout,
            usage: "layout save|restore|protect|edge-crossing",
            summary: "The display arrangement and its protection.",
            mutating: true,
            readBack: "fbdcli layout protect"
        ),
        CommandGrammar(
            command: .group,
            usage: "group list|create|delete|add|remove|mirror|unmirror",
            summary: "Display groups and their members.",
            mutating: true,
            readBack: "fbdcli group list"
        ),
        CommandGrammar(
            command: .edid,
            usage: "edid export|apply|restore|auto",
            summary: "Export the EDID, apply an override, restore the factory one.",
            mutating: true,
            readBack: "fbdcli edid export <id>"
        ),
        CommandGrammar(
            command: .profile,
            usage: "profile list|apply|restore",
            summary: "Colour profiles of a display.",
            mutating: true,
            readBack: "fbdcli profile list <id>"
        ),
        CommandGrammar(
            command: .underscan,
            usage: "underscan <id> [on|off]",
            summary: "Set underscan on a TV (the API is set-only: no read-back).",
            mutating: true,
            readBack: nil
        ),
        CommandGrammar(
            command: .protect,
            usage: "protect config|save|restore",
            summary: "Configuration protection and the saved per-display state.",
            mutating: true,
            readBack: "fbdcli protect config"
        ),
        CommandGrammar(
            command: .http,
            usage: "http on [port]|off|status",
            summary: "The local HTTP control API the app serves.",
            mutating: true,
            readBack: "fbdcli http status"
        ),
        CommandGrammar(
            command: .authToken,
            usage: "auth-token [--reveal]",
            summary: "Explain how to obtain the local API token (prints it only with --reveal).",
            mutating: false
        ),
        CommandGrammar(
            command: .settings,
            usage: "settings",
            summary: "A masked settings dump, for bug reports.",
            mutating: false
        ),
        CommandGrammar(
            command: .pip,
            usage: "pip <id>|--window <id>|--app <bundle-id> [b] [c] [s]",
            summary: "Stream a display, a window or an app in a picture-in-picture window.",
            mutating: true,
            readBack: nil
        ),
        CommandGrammar(
            command: .stream,
            usage: "stream <src-id> <dst-id> [b] [c] [s]",
            summary: "Redirect a display's contents onto another display, full-screen.",
            mutating: true,
            readBack: nil
        ),
        CommandGrammar(
            command: .automation,
            usage: "automation list|add|enable|disable|remove|test|run|log",
            summary: "Per-display event automation rules.",
            mutating: true,
            readBack: "fbdcli automation list"
        ),
        CommandGrammar(
            command: .osd,
            usage: "osd <icon> <0-100>",
            summary: "Show a transient on-screen display (nothing is stored).",
            mutating: false
        ),
        CommandGrammar(
            command: .sysvolume,
            usage: "sysvolume [0-100] [--list] [--device <id|name>]",
            summary: "The Mac's own output volume (CoreAudio).",
            mutating: true,
            readBack: "fbdcli sysvolume"
        ),
        CommandGrammar(
            command: .nightshift,
            usage: "nightshift [0-100]",
            summary: "Get or set the Night Shift strength.",
            mutating: true,
            readBack: "fbdcli nightshift"
        ),
        CommandGrammar(
            command: .truetone,
            usage: "truetone [on|off]",
            summary: "Get or set True Tone.",
            mutating: true,
            readBack: "fbdcli truetone"
        ),
        CommandGrammar(
            command: .darkMode,
            usage: "dark-mode [on|off]",
            summary: "Get or set the system appearance.",
            mutating: true,
            readBack: "fbdcli dark-mode"
        ),
        CommandGrammar(
            command: .dpcd,
            usage: "dpcd <display> [addr] [len]",
            summary: "Read a DisplayPort sink's DPCD over AUX (a read).",
            mutating: false
        ),
        CommandGrammar(
            command: .ambientLight,
            usage: "ambient-light <display> [on|off]",
            summary: "Apple-display auto-brightness (ambient light).",
            mutating: true,
            readBack: "fbdcli ambient-light <id>"
        ),
        CommandGrammar(
            command: .hidpi,
            usage: "hidpi <id> install|remove|status [--preview]",
            summary: "The display's smooth-scaling (HiDPI) ladder: install it, remove it, or report its state.",
            mutating: true,
            readBack: "fbdcli hidpi <id> status"
        ),
        CommandGrammar(
            command: .gammaFloor,
            usage: "gamma-floor <id> [on|off] [value]",
            summary: "The below-floor brightness blend of a display (the value is a threshold in percent).",
            mutating: true,
            readBack: "fbdcli gamma-floor <id>"
        ),
        CommandGrammar(
            command: .display,
            usage: "display <id> disconnect|reconnect [--remember] | --list-remembered",
            summary: "Disconnect or reconnect a display, and list the ones remembered as off.",
            mutating: true,
            readBack: "fbdcli list"
        ),
        CommandGrammar(
            command: .tv,
            usage: "tv <brand> <host> [volume <0-100>|power|input <name>]",
            summary: "Control a TV or AVR over the network.",
            mutating: true,
            readBack: nil
        ),
        CommandGrammar(
            command: .config,
            usage: "config show|protect|favourite|preset|lockdim|keytarget|…",
            summary: "The BetterDisplay-parity settings surfaces.",
            mutating: true,
            readBack: "fbdcli config show"
        ),
        CommandGrammar(
            command: .skill,
            usage: "skill install <claude|codex> [--print] [--path <dir>]",
            summary: "Write the agent skill (SKILL.md) for Claude or Codex.",
            mutating: false
        ),
        CommandGrammar(
            command: .help,
            usage: "help",
            summary: "Show the help.",
            mutating: false
        ),
    ]

    /// The row for a command, or nil when the command has no row (which the
    /// tests treat as a bug: every command must be documented).
    public static func row(for command: Command) -> CommandGrammar? {
        rows.first { $0.command == command }
    }

    /// The command that reads back what `command` wrote, with the display id
    /// substituted. nil when the command has no read-back.
    ///
    /// `id` is the display id the command was given; commands that take no
    /// display id ignore it.
    public static func readBack(for command: Command, id: String? = nil) -> String? {
        guard let template = row(for: command)?.readBack else { return nil }
        guard let id else { return template }
        return template.replacingOccurrences(of: "<id>", with: id)
    }
}
