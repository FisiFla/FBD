/// The agents the fbd skill can be installed for.
public enum SkillTarget: String, CaseIterable {
    case claude
    case codex
}

/// Parsed `fbdcli skill install …` arguments.
///
/// The grammar is deliberately narrow: one subcommand (`install`), one target,
/// and two flags. Anything else is a usage error, so a typo can never
/// silently install something else.
public enum SkillArgs: Equatable {
    /// Install (or print) the skill for one agent.
    case install(target: SkillTarget, printOnly: Bool, path: String?)
    /// `skill` without a subcommand — the usage line.
    case usage(String)
    /// A usage error, with the message to show.
    case invalid(String)

    /// Parse the command's arguments (the words after `skill`).
    public static func parse(_ args: [String]) -> SkillArgs {
        guard let sub = args.first else {
            return .usage("fbdcli: skill: expected install")
        }
        guard sub == "install" else {
            return .invalid("fbdcli: skill: unknown subcommand '\(sub)' (expected install)")
        }

        var rest = Array(args.dropFirst())
        var target: SkillTarget?
        var printOnly = false
        var path: String?

        while !rest.isEmpty {
            let argument = rest.removeFirst()
            switch argument {
            case "--print":
                printOnly = true
            case "--path":
                guard let value = rest.first else {
                    return .invalid("fbdcli: skill install: --path expects a directory")
                }
                rest.removeFirst()
                guard !value.isEmpty else {
                    return .invalid("fbdcli: skill install: --path expects a directory")
                }
                path = value
            default:
                guard let parsed = SkillTarget(rawValue: argument.lowercased()) else {
                    return .invalid(
                        "fbdcli: skill install: unknown target '\(argument)' (expected claude or codex)"
                    )
                }
                guard target == nil else {
                    return .invalid("fbdcli: skill install: expected one target (claude or codex)")
                }
                target = parsed
            }
        }

        guard let target else {
            return .invalid("fbdcli: skill install: expected claude or codex")
        }
        return .install(target: target, printOnly: printOnly, path: path)
    }
}
