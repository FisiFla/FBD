import Foundation

/// The agent skill FBD ships: a `SKILL.md` that teaches an agent the CLI's
/// grammar and its safety contract.
///
/// The text is a compiled-in constant. It is never assembled by running the
/// CLI and reading its help output, so an installed skill is exactly the
/// document this version of FBD ships — and `--print` and the installed file
/// are byte-for-byte the same bytes.
public enum AgentSkill {
    /// The skill's own version. Bumped whenever the text changes, so a
    /// re-install is visibly an update and a reader can tell which revision
    /// it is looking at.
    public static let version = "2"

    /// The file name every agent expects.
    public static let fileName = "SKILL.md"

    /// The directory the skill lives in for one agent, under the user's home.
    public static func defaultDirectory(for target: SkillTarget, home: String) -> String {
        switch target {
        case .claude: return home + "/.claude/skills/fbd"
        case .codex: return home + "/.codex/skills/fbd"
        }
    }

    /// The file the skill is written to. `directory` overrides the agent's
    /// default location; a leading `~` is expanded to the user's home.
    public static func filePath(for target: SkillTarget, directory: String?, home: String) -> String {
        let base: String
        if let directory {
            base = expand(directory, home: home)
        } else {
            base = defaultDirectory(for: target, home: home)
        }
        return base + "/" + fileName
    }

    /// The document, as text.
    public static func text(for target: SkillTarget) -> String {
        frontmatter + body(for: target)
    }

    /// The document, as the exact bytes that are written to disk and printed.
    public static func payload(for target: SkillTarget) -> Data {
        Data(text(for: target).utf8)
    }

    /// Write the skill, replacing whatever was there before.
    ///
    /// The write is atomic and the file is overwritten unconditionally: a
    /// re-install after an FBD upgrade replaces the old document instead of
    /// merging into it, so the installed skill never mixes two versions.
    @discardableResult
    public static func install(target: SkillTarget, directory: String?, home: String) throws -> String {
        let path = filePath(for: target, directory: directory, home: home)
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try payload(for: target).write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    // MARK: - The document

    /// The YAML frontmatter both agents read.
    private static let frontmatter = """
        ---
        name: fbd
        description: "Control the user's displays from the command line with fbdcli (Free Better Display): brightness, contrast, volume, mute, input source, modes, HDR and XDR upscaling, smooth scaling, below-floor brightness, virtual screens, software filters, EDID, colour profiles, display groups, disconnecting a display, Night Shift, True Tone and TV control. Use when the user wants to read or change a display, a monitor or a TV."
        version: \(version)
        ---


        """

    /// The body: the grammar, the token model, the write contract and the
    /// honest vocabulary.
    private static func body(for target: SkillTarget) -> String {
        """
        # fbdcli — Free Better Display

        FBD is a macOS menu-bar app for external displays. `fbdcli` is its
        command-line interface: the same actions, scriptable, with a stable
        exit code.

        Skill version \(version). This file is overwritten on every install —
        re-run `fbdcli skill install \(target.rawValue)` after upgrading FBD to
        refresh it. \(convention(for: target))

        ## Before you write

        - **Get the display id first.** `fbdcli list` prints one line per
          display: id, name, type, current mode, HiDPI, and whether DDC and
          Apple brightness are available. Ids are not stable across reboots,
          cable changes or docking stations — read the list again instead of
          remembering an id.
        - **A running app owns the bus.** With FBD.app running, `fbdcli`
          sends writes to the app over its local HTTP API (one driver on the
          DDC bus). With the app closed it drives the hardware directly.
          `--direct` forces the direct path.
        - **Exit codes.** `0` success, `1` a usage or argument error, `2` the
          operation failed, `75` the reply was lost — the write may have
          applied, so read the state back before doing anything else.

        ## Grammar

        \(grammarTable())

        The `read back with` column is the command to run after a write to
        see what the display actually holds. Where it says "none", no command
        prints that state, so the write cannot be verified from the CLI.

        Two of the commands need the user in the loop, so say what is about
        to happen before you run them:

        - `hidpi <id> install` asks macOS for an administrator password: the
          override lives under /Library, so only an administrator may write
          it. `hidpi <id> install --preview` prints the ladder instead and
          installs nothing.
        - `display <id> disconnect` puts the display's screen to black, and
          `--remember` keeps it off when it is plugged back in.

        ## The token is a secret

        The local HTTP API token grants full control of the user's displays.

        - `fbdcli auth-token` explains how to obtain the token; it never prints the token itself.
        - `fbdcli auth-token --reveal` prints the token. Pipe it into a variable
          (`TOKEN=$(fbdcli auth-token --reveal)`).
        - Never paste it into a chat, a log, a commit, a bug report or your own
          transcript, and never echo it back.
        - `fbdcli` sends the token itself, so you never need to read the token
          to use the CLI.

        ## Writes: read back, never retry blindly

        A write ends in one of four ways, and the CLI says which:

        1. **Applied** — the app confirmed it, and the CLI prints the value it
           read back.
        2. **Refused** — the app answered with an error, so nothing was
           written.
        3. **Not sent** — the request never reached the app (or there was no
           control path), so nothing was written.
        4. **Reply lost** — the request went out, but the answer never came
           back:

               fbdcli: brightness 1: the app did not answer in time — the command may have applied. Verify the state with: fbdcli brightness 1

           The app may have committed the write before the reply went missing.
           **Do not re-issue it.** Run the read-back command first: if it
           already shows the value you asked for, the write did land, and a
           second attempt would apply the change twice. Exit code `75` marks
           this case.

        A non-zero exit code is never a reason to repeat a write. Read the
        state, then decide.

        ## Honest claims

        Use these words exactly, and only when they are true:

        - **"may have applied"** — the write's reply was lost; the state is
          unknown.
        - **"not verified on hardware"** — the command reported success but
          nothing read the value back (no physical display attached, a virtual
          screen, or no read-back available). Say this instead of claiming the
          change is on the screen.

        Never claim a display was changed because a command exited `0`. That
        says the request was accepted, not that a human can see it.

        """
    }

    /// The grammar table, generated from the CLI's own vocabulary table.
    private static func grammarTable() -> String {
        var lines = [
            "| command | what it does | changes state | read back with |",
            "| --- | --- | --- | --- |",
        ]
        for row in CLIGrammar.rows {
            let readBack: String
            if row.mutating {
                readBack = row.readBack ?? "none — the CLI cannot read that state back"
            } else {
                readBack = "—"
            }
            lines.append("| `\(row.usage)` | \(row.summary) | \(row.mutating ? "yes" : "no") | \(readBack) |")
        }
        return lines.joined(separator: "\n")
    }

    /// The agent convention this document follows.
    private static func convention(for target: SkillTarget) -> String {
        switch target {
        case .claude:
            return "This document follows the Claude skill convention: a `SKILL.md` with YAML frontmatter (`name`, `description`) inside `~/.claude/skills/<name>/`."
        case .codex:
            return "This document follows the Codex skill convention: a `SKILL.md` with YAML frontmatter (`name`, `description`) inside `~/.codex/skills/<name>/`."
        }
    }

    /// Expand a leading `~` to the user's home directory.
    private static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + "/" + String(path.dropFirst(2)) }
        return path
    }
}
