import Foundation

/// A display or system event an automation rule can fire on.
public enum AutomationEvent: String, Codable, CaseIterable, Sendable {
    /// A display transitioned offline → online.
    case displayConnected
    /// A display transitioned online → offline.
    case displayDisconnected
    /// The system is about to sleep.
    case systemSleep
    /// The system woke.
    case systemWake
    /// **Invoked by the user, never by the system.** A rule with this event is a
    /// manual control: it exists to be run on demand, which is why the scheduler
    /// refuses to select one for any event.
    ///
    /// ON/OFF and state-query controls are each a manual rule — a control that
    /// queries state is a manual rule whose shell output lands in the run log.
    case manual

    /// System events are not attributable to one display, so only rules with an
    /// empty display identity (an "any display" rule) fire for them.
    public var isSystemEvent: Bool {
        self == .systemSleep || self == .systemWake
    }

    public var label: String {
        switch self {
        case .displayConnected: return "display connected"
        case .displayDisconnected: return "display disconnected"
        case .systemSleep: return "system sleep"
        case .systemWake: return "system wake"
        case .manual: return "run manually"
        }
    }

    /// Short form used by the CLI.
    public var token: String {
        switch self {
        case .displayConnected: return "connect"
        case .displayDisconnected: return "disconnect"
        case .systemSleep: return "sleep"
        case .systemWake: return "wake"
        case .manual: return "manual"
        }
    }

    public init?(token: String) {
        guard let match = Self.allCases.first(where: { $0.token == token.lowercased() }) else { return nil }
        self = match
    }
}

/// How a rule's payload is executed.
public enum AutomationActionKind: String, Codable, CaseIterable, Sendable {
    /// Run the payload through `/bin/zsh -c`.
    case shellScript
    /// Open the payload as a URL (or file) with `/usr/bin/open`.
    case url
    /// Deliver a user notification. Runs **in-process** — no subprocess and no
    /// shell — which is why it is an action kind rather than a special payload.
    case notification

    public var token: String {
        switch self {
        case .shellScript: return "shell"
        case .url: return "url"
        case .notification: return "notify"
        }
    }

    public init?(token: String) {
        guard let match = Self.allCases.first(where: { $0.token == token.lowercased() }) else { return nil }
        self = match
    }
}

/// One user-defined automation.
///
/// **Opt-in by construction:** a rule exists only because someone created it,
/// and `enabled` defaults on only for rules created deliberately. Nothing is
/// ever inferred, imported or enabled implicitly.
public struct AutomationRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// `Display.identityKey` this rule belongs to. **Empty means "any
    /// display"** — which is also how a rule is addressed to a system event,
    /// since those cannot be attributed to one display.
    public var displayIdentityKey: String
    public var event: AutomationEvent
    public var kind: AutomationActionKind
    public var payload: String
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        displayIdentityKey: String,
        event: AutomationEvent,
        kind: AutomationActionKind,
        payload: String,
        enabled: Bool = true
    ) {
        self.id = id
        self.displayIdentityKey = displayIdentityKey
        self.event = event
        self.kind = kind
        self.payload = payload
        self.enabled = enabled
    }

    /// Whether this rule is addressed to `identityKey`. A nil identity means a
    /// system event, which only "any display" rules answer.
    public func matches(identityKey: String?) -> Bool {
        guard let identityKey else { return displayIdentityKey.isEmpty }
        return displayIdentityKey.isEmpty || displayIdentityKey == identityKey
    }
}

/// Execution limits for one action. Clamped so a rule can never run unbounded
/// or flap-storm the machine.
public struct AutomationLimits: Equatable, Sendable {
    /// Hard kill deadline for a single action.
    public var timeout: TimeInterval
    /// Minimum gap between two runs of the same rule. Display topology changes
    /// arrive in bursts (dock, wake, resolution change), so without this a
    /// single dock event would run the same script several times.
    public var minimumInterval: TimeInterval

    public static let maxTimeout: TimeInterval = 120
    public static let maxMinimumInterval: TimeInterval = 3600

    public init(timeout: TimeInterval = 10, minimumInterval: TimeInterval = 5) {
        self.timeout = min(max(timeout, 1), Self.maxTimeout)
        self.minimumInterval = min(max(minimumInterval, 0), Self.maxMinimumInterval)
    }

    public static let `default` = AutomationLimits()
}

/// A resolved process invocation — pure data, so the shape of what would run is
/// assertable without starting anything.
public struct AutomationInvocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
}

/// Builds the invocation for a rule. Deliberately pure: this is the part worth
/// testing, and testing it must never start a process.
public enum AutomationCommand {
    /// Environment handed to every action, so a script knows what fired it
    /// without re-querying the system.
    public static func environment(
        event: AutomationEvent,
        displayIdentifier: String? = nil,
        displayName: String? = nil,
        displayIdentityKey: String? = nil
    ) -> [String: String] {
        var environment = [
            "FBD_EVENT": event.rawValue,
            "FBD_EVENT_LABEL": event.label,
        ]
        if let displayIdentifier { environment["FBD_DISPLAY_ID"] = displayIdentifier }
        if let displayName { environment["FBD_DISPLAY_NAME"] = displayName }
        if let displayIdentityKey { environment["FBD_DISPLAY_IDENTITY"] = displayIdentityKey }
        return environment
    }

    public static func invocation(
        kind: AutomationActionKind,
        payload: String,
        environment: [String: String] = [:]
    ) -> AutomationInvocation? {
        switch kind {
        case .shellScript:
            return AutomationInvocation(executable: "/bin/zsh", arguments: ["-c", payload], environment: environment)
        case .url:
            return AutomationInvocation(executable: "/usr/bin/open", arguments: [payload], environment: environment)
        case .notification:
            // A notification starts nothing, so there is no invocation to return.
            // `effect(kind:payload:environment:)` is the total entry point.
            return nil
        }
    }

    /// What a kind actually does. Total — every kind resolves to something
    /// runnable — so callers never have to decide what a nil invocation means.
    public static func effect(
        kind: AutomationActionKind,
        payload: String,
        environment: [String: String] = [:]
    ) -> AutomationEffect {
        switch kind {
        case .shellScript, .url:
            // `invocation` is non-nil for exactly these two kinds; the fallback
            // keeps this total without a force-unwrap.
            return .run(invocation(kind: kind, payload: payload, environment: environment)
                ?? AutomationInvocation(executable: "/usr/bin/false", arguments: [], environment: environment))
        case .notification:
            let parsed = AutomationNotification.parse(payload)
            return .notify(title: parsed.title, body: parsed.body)
        }
    }
}

/// A notification action's payload, parsed.
public enum AutomationNotification {
    /// `Title | body`, split on the **first** `|` so a body may contain more.
    ///
    /// With no separator the whole payload is the body and the title falls back to
    /// FBD's own name — which is what makes `notify "Coffee brewed"` do the
    /// obvious thing instead of demanding a separator nobody asked for.
    public static func parse(_ payload: String) -> (title: String, body: String) {
        guard let separator = payload.firstIndex(of: "|") else {
            return ("FBD", payload.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let title = payload[payload.startIndex..<separator].trimmingCharacters(in: .whitespaces)
        let body = payload[payload.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? "FBD" : title, body)
    }
}

/// What an action does: start a process, or deliver a notification.
///
/// A sum type rather than one struct with an optional field, so there is no
/// meaningless value for the case that starts nothing — a notification has no
/// executable, and inventing one would put a lie in the run log.
public enum AutomationEffect: Equatable, Sendable {
    case run(AutomationInvocation)
    case notify(title: String, body: String)

    /// Execute this effect, mapping it to the outcome the run log records.
    ///
    /// Non-isolated on purpose: the controller calls it both from the main actor
    /// (a manual run) and from its serial queue (an event), and duplicating this
    /// mapping in two places is how the two paths would drift.
    public func perform(
        executor: AutomationExecuting,
        notifier: AutomationNotifying,
        timeout: TimeInterval
    ) -> (exitCode: Int32, output: String, timedOut: Bool) {
        switch self {
        case .run(let invocation):
            return executor.execute(invocation, timeout: timeout)
        case .notify(let title, let body):
            // A notification has no exit code, and the controller cannot know
            // whether the system drew a banner — only that the request was handed
            // over. The wording says that rather than claiming a delivery.
            let handedOver = notifier.deliver(title: title, body: body)
            return (
                handedOver ? 0 : 1,
                handedOver
                    ? "notification handed to Notification Centre: \(title)"
                    : "notification could not be handed to Notification Centre",
                false
            )
        }
    }
}

/// What one action did — the "inspect what ran and what it returned" surface.
public struct AutomationRunRecord: Equatable, Sendable {
    public let ruleID: UUID
    public let event: AutomationEvent
    public let date: Date
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool

    public init(ruleID: UUID, event: AutomationEvent, date: Date, exitCode: Int32, output: String, timedOut: Bool) {
        self.ruleID = ruleID
        self.event = event
        self.date = date
        self.exitCode = exitCode
        self.output = output
        self.timedOut = timedOut
    }

    public var succeeded: Bool { !timedOut && exitCode == 0 }
}

/// Runs one action. Injected so the controller's decision-making is testable
/// without ever starting a process, and so a fake can observe what *would* run.
/// `Sendable` because `DisplayAutomationController` calls this from its own
/// serial queue: the reference crosses a concurrency boundary, and declaring
/// that is what lets the compiler check the real conformance rather than warn.
/// The shipped executor is a final class with no stored properties, so it
/// satisfies this as written.
public protocol AutomationExecuting: AnyObject, Sendable {
    func execute(
        _ invocation: AutomationInvocation,
        timeout: TimeInterval
    ) -> (exitCode: Int32, output: String, timedOut: Bool)
}

/// Chooses which rules fire. Free and pure: every input is a parameter, so the
/// matching rules and the rate limit are assertable without a clock, a
/// controller or a process.
public enum AutomationScheduler {
    public static func dueRules(
        _ rules: [AutomationRule],
        event: AutomationEvent,
        identityKey: String?,
        lastRun: [UUID: Date],
        now: Date,
        limits: AutomationLimits
    ) -> [AutomationRule] {
        // A manual control is never *scheduled*. It exists to be invoked, and
        // selecting one here would let an event storm run the user's commands
        // unbidden — so this refuses the manual event itself rather than merely
        // manual rules, which keeps the guarantee even if a caller passes it by
        // mistake.
        guard event != .manual else { return [] }
        return rules.filter { rule in
            guard rule.enabled, rule.event == event, rule.matches(identityKey: identityKey) else {
                return false
            }
            guard let last = lastRun[rule.id] else { return true }
            return now.timeIntervalSince(last) >= limits.minimumInterval
        }
    }
}
