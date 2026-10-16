import FBDCLIParser
import FBDCore
import CoreGraphics
import Foundation

/// `fbdcli automation …` — per-display event automation: run a shell script or
/// open a URL when a display connects/disconnects, or when the system sleeps or
/// wakes.
///
/// **Opt-in**: nothing runs unless a rule exists for it. Rules are persisted in
/// the shared suite, so one added here applies to the running app too.
/// Process-wide controller so `add` and `test` see the same rule set.
@MainActor
private let cliAutomation = DisplayAutomationController()

@MainActor
func cmdAutomation(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let sub = args.first else {
        print("fbdcli: automation: expected list, log, add, remove, enable, disable, test or run")
        return 1
    }
    let rest = Array(args.dropFirst())

    switch sub {
    case "list":
        let rules = cliAutomation.allRules
        guard !rules.isEmpty else {
            print("no automation rules")
            return 0
        }
        for rule in rules {
            let scope = rule.displayIdentityKey.isEmpty ? "any display" : rule.displayIdentityKey
            print("\(rule.id.uuidString)  \(rule.enabled ? "on " : "off")  \(scope)  \(rule.event.token)  \(rule.kind.token)  \(rule.payload)")
        }
        return 0

    case "log":
        let runs = cliAutomation.recentRuns()
        guard !runs.isEmpty else {
            print("no runs recorded in this session")
            return 0
        }
        for run in runs {
            print("\(run.ruleID.uuidString)  \(run.event.token)  exit \(run.exitCode)\(run.timedOut ? " (timed out)" : "")")
            let output = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty { print("  \(output)") }
        }
        return 0

    case "add":
        // Derived from the enums, so a new event or kind cannot leave this
        // message lying about what is accepted.
        let eventTokens = AutomationEvent.allCases.map(\.token).joined(separator: ", ")
        let kindTokens = AutomationActionKind.allCases.map(\.token).joined(separator: ", ")
        guard rest.count >= 4 else {
            print("fbdcli: automation add: expected <display-id|any> <\(eventTokens)> <\(kindTokens)> <payload…>")
            return 1
        }
        guard let event = AutomationEvent(token: rest[1]) else {
            print("fbdcli: automation add: unknown event '\(rest[1])' (\(eventTokens))")
            return 1
        }
        guard let kind = AutomationActionKind(token: rest[2]) else {
            print("fbdcli: automation add: unknown kind '\(rest[2])' (\(kindTokens))")
            return 1
        }
        let identityKey: String
        if rest[0].lowercased() == "any" {
            identityKey = ""
        } else if let display = requireDisplay(rest[0], in: controller) {
            identityKey = display.identityKey
        } else {
            return 1
        }
        // The payload is everything that follows, so a script may contain
        // spaces without quoting gymnastics.
        let payload = rest.dropFirst(3).joined(separator: " ")
        guard !payload.isEmpty else {
            print("fbdcli: automation add: empty payload")
            return 1
        }
        let rule = cliAutomation.addRule(
            displayIdentityKey: identityKey,
            event: event,
            kind: kind,
            payload: payload
        )
        print("added \(rule.id.uuidString) — \(event.token) on \(identityKey.isEmpty ? "any display" : identityKey)")
        if event == .manual {
            // A manual control is useless without knowing how to invoke it.
            print("run it with: fbdcli automation run \(rule.id.uuidString)")
        }
        return 0

    case "remove", "enable", "disable", "test", "run":
        guard let raw = rest.first, let id = UUID(uuidString: raw) else {
            print("fbdcli: automation \(sub): expected a rule id")
            return 1
        }
        switch sub {
        case "remove":
            guard cliAutomation.removeRule(id: id) else {
                print("fbdcli: automation remove: no rule \(raw)")
                return 1
            }
            print("removed \(raw)")
            return 0
        case "enable", "disable":
            guard cliAutomation.setEnabled(sub == "enable", ruleID: id) else {
                print("fbdcli: automation \(sub): no rule \(raw)")
                return 1
            }
            print("\(sub)d \(raw)")
            return 0
        default:
            guard let rule = cliAutomation.rule(withID: id) else {
                print("fbdcli: automation \(sub): no rule \(raw)")
                return 1
            }
            // A notification rule has to run in the app. `fbdcli` is a bare binary
            // with no bundle identity and no notification authorisation, so a
            // request from here is accepted and then dropped by the system —
            // reporting success would be a lie about something the user can see did
            // not happen.
            if rule.kind == .notification {
                print("fbdcli: automation \(sub): a notification rule runs in the app — use Settings → Automation.")
                return 1
            }
            // A manual rule is a control the user invokes, so it is named as one;
            // `test` and `run` are the same action, spelled for both intents.
            let what = rule.event == .manual ? "manual control" : "\(rule.kind.token) rule"
            print("running \(what) (timeout \(Int(AutomationLimits.default.timeout))s)…")
            let record = cliAutomation.runSynchronously(rule)
            let output = record.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty { print(output) }
            print("exit \(record.exitCode)\(record.timedOut ? " (timed out)" : "")")
            return record.succeeded ? 0 : 2
        }

    default:
        print("fbdcli: automation: unknown subcommand '\(sub)'")
        return 1
    }
}
