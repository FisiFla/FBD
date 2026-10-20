import FBDCLIParser
import Foundation

/// `fbdcli skill install <claude|codex> [--print] [--path <dir>]` — write the
/// agent skill (a `SKILL.md` that teaches an agent the CLI's grammar and its
/// safety contract) where the agent expects it.
///
/// The document is a compiled-in constant (`AgentSkill`), so `--print` and the
/// installed file are the same bytes: what an agent reads from disk is
/// exactly what the CLI would have printed.
@MainActor
func cmdSkill(args: [String]) -> Int32 {
    switch SkillArgs.parse(args) {
    case .usage(let message), .invalid(let message):
        print(message)
        return 1
    case .install(let target, let printOnly, let path):
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if printOnly {
            // The exact bytes of the file, with nothing added: a caller can
            // redirect stdout straight into a file.
            FileHandle.standardOutput.write(AgentSkill.payload(for: target))
            return 0
        }
        do {
            let written = try AgentSkill.install(target: target, directory: path, home: home)
            let targetName = target.rawValue
            log.notice("installed the fbd skill for \(targetName): \(written)")
            print("installed the fbd skill for \(targetName): \(written)")
            return 0
        } catch {
            print("fbdcli: skill install: could not write the skill file: \(error.localizedDescription)")
            return 2
        }
    }
}
