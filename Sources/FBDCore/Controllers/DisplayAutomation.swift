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
        }
    }

    /// Short form used by the CLI.
    public var token: String {
        switch self {
        case .displayConnected: return "connect"
        case .displayDisconnected: return "disconnect"
        case .systemSleep: return "sleep"
        case .systemWake: return "wake"
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

    public var token: String {
        switch self {
        case .shellScript: return "shell"
        case .url: return "url"
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
    ) -> AutomationInvocation {
        switch kind {
        case .shellScript:
            return AutomationInvocation(executable: "/bin/zsh", arguments: ["-c", payload], environment: environment)
        case .url:
            return AutomationInvocation(executable: "/usr/bin/open", arguments: [payload], environment: environment)
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
        rules.filter { rule in
            guard rule.enabled, rule.event == event, rule.matches(identityKey: identityKey) else {
                return false
            }
            guard let last = lastRun[rule.id] else { return true }
            return now.timeIntervalSince(last) >= limits.minimumInterval
        }
    }
}
