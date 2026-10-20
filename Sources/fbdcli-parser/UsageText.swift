import Foundation

/// The `fbdcli help` text.
///
/// It lives in the parser library so the agent skill's grammar table can be
/// checked against it, and so a command can never be added to the vocabulary
/// without appearing in the help.
public enum UsageText {
    /// The full usage text, printed by `help` and on argument errors.
    public static let text = """
    fbdcli — Free Better Display command-line interface

    Usage: fbdcli <command> [args]

    Commands:
      list [--json]                 List displays (one line per display, or JSON;
                                    --json reads the hardware directly, even when
                                    the app is running)
      info <id> [--json]            Show full detail for a display (or JSON, direct)
      report [file]                 Detailed report of every display, for a bug
                                    report (prints, or writes to <file>)
      report --dpcd <hex>           Decode a supplied DPCD dump (repeatable; prefix
                                    with a hex address, e.g. 68028:00 for HDCP)
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
      rotate <id> <0|90|180|270>    Rotate a display
      filter <id> [off]             Apply a full-screen software filter:
                                    <contrast> <saturation> <gamma> <temperature>
                                    [--invert] [--sharpness n] [--radius px]
                                    [--zoom n] [--pan x y] [--lut path.cube];
                                    'off' clears it (needs Screen Recording)
      disable <id>                  Disable a display (black screen until re-enabled)
      enable <id>                   Re-enable a disabled display
      layout save                   Save the current display arrangement
      layout restore                Restore the saved arrangement
      layout protect [on|off]       Get or set layout protection
      layout edge-crossing [on|off] Get or set pointer crossing between misaligned displays
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
      auth-token                    Explain how to obtain the local HTTP API token
                                    (needed for curl and other HTTP clients); the
                                    token is printed only with --reveal
      auth-token --reveal            Print the local HTTP API token (a secret)
      settings                      Print a masked settings dump (for bug reports)
      pip <id> [b] [c] [s]          Stream a display in a picture-in-picture window
                                    (optional brightness/contrast/saturation, 1 =
                                    none). Streams until the window closes or a
                                    key is pressed
      pip --window <win-id> [b] [c] [s]
                                    Stream a single window instead of a display
      pip --app <bundle-id> [b] [c] [s]
                                    Stream every window of an application
      pip list                      List capturable displays, windows and apps
      pip stop                      Stop the active CLI PiP stream
      stream <src-id> <dst-id> [b] [c] [s]
                                    Redirect a display's contents onto another
                                    display, full-screen (local streaming); optional
                                    brightness/contrast/saturation, 1 = none
      stream stop                   Stop the active CLI stream
      automation list               List per-display automation rules
      automation add <id|any> <connect|disconnect|sleep|wake|manual> <shell|url|notify> <payload…>
                                    Run a shell script, open a URL, or post a
                                    notification on a display event. "manual" makes a
                                    control you invoke yourself — ON and OFF are two
                                    of them. Opt-in: nothing runs without a rule.
      automation enable|disable|remove <rule-id>
      automation test|run <rule-id>   Run a rule now and show its output
      automation log                Show runs from this session
      osd <icon> <0-100>            Show a transient OSD HUD (e.g. sun.max,
                                    speaker.wave.2) at the given percentage
      sysvolume [0-100] [--list] [--device <id|name>]
                                    Mac's own output volume (CoreAudio)
      nightshift [0-100]            Get or set Night Shift strength
      truetone [on|off]             Get or set True Tone
      dark-mode [on|off]            Get or set system Dark Mode
      dpcd <display> [addr] [len]   Read a DisplayPort sink's DPCD over AUX (a
                                    read; hex address, default 0x0000)
      ambient-light <display> [on|off]
                                    Apple display auto-brightness (ambient light);
                                    the state doubles as the capability probe
      hidpi <id> install|remove|status [--preview]
                                    The display's smooth-scaling (HiDPI) ladder:
                                    install it, remove it, or report its state.
                                    --preview prints the ladder first and
                                    installs nothing; an install asks macOS for
                                    an administrator password
      gamma-floor <id> [on|off] [value]
                                    The below-floor brightness blend of a
                                    display (it reaches past the panel's own
                                    floor; it needs Screen Recording
                                    permission). The value is the threshold
                                    in percent (0-100). Bare: report the state
      display <id> disconnect [--remember]
                                    Disconnect a display (black screen);
                                    --remember keeps it off when it is plugged
                                    back in
      display <id> reconnect         Reconnect a display (and forget the
                                    "keep it off" note)
      display --list-remembered      List the displays FBD is remembering as
                                    off
      tv <brand> <host> [action]    Control a TV/AVR over the network: brand is
                                    lg, samsung, philips, or yamaha; action is
                                    volume <0-100>, power, or input <name>
                                    (requires the device in network/API mode)
                                    A saved device name may replace <brand> <host>:
                                    `fbdcli tv living-room volume 20`
      config [show]                 BetterDisplay-parity settings: per-property
                                    configuration protection, resolution favourites,
                                    lock dimming, the keyboard control target, and
                                    display-group sync policy. Subcommands: show,
                                    protect <id> [properties], favourite <id>
                                    list|save|apply [slot], lockdim [on|off],
                                    lockdim-target [0-100], keytarget
                                    [mouse|focused|all|audio], group-policy
                                    <group> [policy], group-enabled <group> [on|off],
                                    group-sync <group> <0-100>, connections
                                    connect-all|disconnect-all-but-main|swap-identical,
                                    model <key> [value], device list|add|remove,
                                    identity [method], transfer <from-id> <to-id>
                                    [--overwrite], vscreen
                                    list|associate|disassociate|apply,
                                    uiscale [on|off|show]
      skill install <claude|codex> [--print] [--path <dir>]
                                    Write the agent skill (SKILL.md) for Claude or
                                    Codex: the CLI's grammar, the token model and
                                    the read-back contract. --print dumps the file
                                    to stdout instead of writing it
      help                          Show this help

    Exit codes: 0 success, 1 usage/argument error, 2 operation failed,
    75 the reply was lost (the write may have applied — read the state back
    before re-issuing it).
    """
}
