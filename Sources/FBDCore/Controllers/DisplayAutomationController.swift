import AppKit
import CoreGraphics
import Foundation
import os

/// The real executor: one process per action, with a hard timeout and a cap on
/// captured output.
///
/// Writes are gated nowhere else — the rule layer decides *whether* to run, and
/// this decides only *how*.
public final class ProcessAutomationExecutor: AutomationExecuting {
    /// Cap on captured output so a runaway script cannot fill memory.
    public static let maxOutputBytes = 16 * 1024

    /// A lock-protected flag, since the timeout fires on another queue while
    /// the caller is blocked in `waitUntilExit`.
    private final class Flag {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    public init() {}

    public func execute(
        _ invocation: AutomationInvocation,
        timeout: TimeInterval
    ) -> (exitCode: Int32, output: String, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        // Inherit the app's environment so PATH etc. behave as the user
        // expects, then layer the FBD_* variables on top.
        process.environment = ProcessInfo.processInfo.environment
            .merging(invocation.environment) { _, ruleValue in ruleValue }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "failed to launch \(invocation.executable): \(error.localizedDescription)", false)
        }

        // SIGTERM at the deadline, SIGKILL two seconds later if it is still up.
        let timedOutFlag = Flag()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            timedOutFlag.set()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        // Drain BEFORE waiting: a child that fills the pipe buffer would
        // otherwise deadlock against a parent that is waiting for it to exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let truncated = data.count > Self.maxOutputBytes ? data.prefix(Self.maxOutputBytes) : data
        var output = String(decoding: truncated, as: UTF8.self)
        if data.count > Self.maxOutputBytes { output += "\n… (output truncated)" }
        return (process.terminationStatus, output, timedOutFlag.isSet)
    }
}

/// Per-display automation: run a user-defined shell script or URL when a
/// display connects or disconnects, or when the system sleeps or wakes.
///
/// **Security posture.** This is the one place FBD executes arbitrary
/// code, and it is deliberately the narrowest shape that is useful:
///
/// - A rule exists only because someone created one; `enabled` gates it
///   further, and nothing is ever inferred or inherited.
/// - Rules are addressed to one display's `identityKey`, or to "any display".
/// - Every action is killed at `AutomationLimits.timeout` and rate-limited to
///   one run per `minimumInterval`, because topology changes arrive in bursts.
/// - Execution happens on a **serial** queue, so one action is in flight at a
///   time and an event storm cannot stampede the machine.
/// - The executor is a seam, so tests assert what *would* run without ever
///   starting a process.
///
/// MainActor, like `DisplayController` and `ConfigProtectionController`: the
/// observers run on the main queue.
@MainActor
public final class DisplayAutomationController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "DisplayAutomation")
    private let executor: AutomationExecuting
    private let limits: AutomationLimits
    /// Serial by design — a concurrency limit of one.
    private let queue = DispatchQueue(label: "dev.fisifla.fbd.automation")

    private var rules: [AutomationRule]
    /// Last run per rule, for the rate limit.
    private var lastRun: [UUID: Date] = [:]
    private var runLog: [AutomationRunRecord] = []
    private static let maxLogEntries = 50

    private var observers: [NSObjectProtocol] = []
    /// Displays online at the last topology tick, with what we need to name
    /// them after they have gone.
    private struct KnownDisplay: Equatable {
        let identityKey: String
        let name: String
    }
    private var knownOnline: [CGDirectDisplayID: KnownDisplay] = [:]
    private var started = false

    public init(
        executor: AutomationExecuting = ProcessAutomationExecutor(),
        limits: AutomationLimits = .default
    ) {
        self.executor = executor
        self.limits = limits
        self.rules = Settings.loadAutomationRules()
    }

    // MARK: - Rules

    public var allRules: [AutomationRule] { rules }

    /// Recent runs, newest first — what ran and what it returned.
    public func recentRuns() -> [AutomationRunRecord] { runLog }

    @discardableResult
    public func addRule(
        displayIdentityKey: String,
        event: AutomationEvent,
        kind: AutomationActionKind,
        payload: String
    ) -> AutomationRule {
        let rule = AutomationRule(
            displayIdentityKey: displayIdentityKey,
            event: event,
            kind: kind,
            payload: payload
        )
        rules.append(rule)
        Settings.saveAutomationRules(rules)
        return rule
    }

    @discardableResult
    public func removeRule(id: UUID) -> Bool {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return false }
        rules.remove(at: index)
        Settings.saveAutomationRules(rules)
        return true
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, ruleID: UUID) -> Bool {
        guard let index = rules.firstIndex(where: { $0.id == ruleID }) else { return false }
        rules[index].enabled = enabled
        Settings.saveAutomationRules(rules)
        return true
    }

    public func rule(withID id: UUID) -> AutomationRule? {
        rules.first { $0.id == id }
    }

    // MARK: - Manual run

    /// Run one rule now, synchronously, bypassing the rate limit — the "test
    /// this rule" path, and the only way to exercise a rule without waiting for
    /// its event. Returns the record so the caller can show the output.
    @discardableResult
    public func runSynchronously(_ rule: AutomationRule) -> AutomationRunRecord {
        let environment = AutomationCommand.environment(
            event: rule.event,
            displayIdentityKey: rule.displayIdentityKey.isEmpty ? nil : rule.displayIdentityKey
        )
        let invocation = AutomationCommand.invocation(
            kind: rule.kind,
            payload: rule.payload,
            environment: environment
        )
        let outcome = executor.execute(invocation, timeout: limits.timeout)
        let record = AutomationRunRecord(
            ruleID: rule.id,
            event: rule.event,
            date: Date(),
            exitCode: outcome.exitCode,
            output: outcome.output,
            timedOut: outcome.timedOut
        )
        appendRun(record)
        return record
    }

    // MARK: - Observation

    /// Observe display topology and system sleep/wake. Idempotent.
    public func start(controller: DisplayController) {
        guard !started else { return }
        started = true
        // Seed with what is online now, so the first notification (posted by
        // the initial refresh) is not mistaken for a connect.
        knownOnline = Self.onlineDisplays(controller)

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .fbdDisplaysChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDisplaysChanged(controller: controller) }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemEvent(.systemSleep) }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemEvent(.systemWake) }
        })
    }

    public func stop() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
            workspace.removeObserver(observer)
        }
        observers.removeAll()
        started = false
    }

    private static func onlineDisplays(_ controller: DisplayController) -> [CGDirectDisplayID: KnownDisplay] {
        var result: [CGDirectDisplayID: KnownDisplay] = [:]
        for display in controller.displays where display.isOnline {
            result[display.id] = KnownDisplay(identityKey: display.identityKey, name: display.name)
        }
        return result
    }

    private func handleDisplaysChanged(controller: DisplayController) {
        let online = Self.onlineDisplays(controller)
        let appeared = online.filter { knownOnline[$0.key] == nil }
        let disappeared = knownOnline.filter { online[$0.key] == nil }
        knownOnline = online

        for (id, known) in appeared {
            fireEvent(.displayConnected, displayID: id, known: known)
        }
        for (id, known) in disappeared {
            // The display is gone from the controller by now, so the cached
            // name and identity are the only way to describe it.
            fireEvent(.displayDisconnected, displayID: id, known: known)
        }
    }

    private func handleSystemEvent(_ event: AutomationEvent) {
        fireEvent(event, displayID: nil, known: nil)
    }

    private func fireEvent(_ event: AutomationEvent, displayID: CGDirectDisplayID?, known: KnownDisplay?) {
        // Re-read before deciding: the CLI writes rules into the same shared
        // suite, so a rule added by `fbdcli automation add` takes effect
        // without restarting the app.
        rules = Settings.loadAutomationRules()
        let now = Date()
        let due = AutomationScheduler.dueRules(
            rules,
            event: event,
            identityKey: known?.identityKey,
            lastRun: lastRun,
            now: now,
            limits: limits
        )
        guard !due.isEmpty else { return }

        for rule in due {
            lastRun[rule.id] = now
            fire(
                rule,
                event: event,
                displayIdentifier: displayID.map(String.init),
                displayName: known?.name,
                identityKey: known?.identityKey
            )
        }
    }

    /// Execute one rule on the serial queue. Never blocks a caller, never
    /// traps: a failure is logged and recorded.
    private func fire(
        _ rule: AutomationRule,
        event: AutomationEvent,
        displayIdentifier: String?,
        displayName: String?,
        identityKey: String?
    ) {
        let environment = AutomationCommand.environment(
            event: event,
            displayIdentifier: displayIdentifier,
            displayName: displayName,
            displayIdentityKey: identityKey
        )
        let invocation = AutomationCommand.invocation(
            kind: rule.kind,
            payload: rule.payload,
            environment: environment
        )
        log.notice("automation \(rule.kind.rawValue) rule for \(event.rawValue) on \(displayName ?? "system")")

        let executor = self.executor
        let timeout = limits.timeout
        let ruleID = rule.id
        queue.async { [weak self] in
            let outcome = executor.execute(invocation, timeout: timeout)
            let record = AutomationRunRecord(
                ruleID: ruleID,
                event: event,
                date: Date(),
                exitCode: outcome.exitCode,
                output: outcome.output,
                timedOut: outcome.timedOut
            )
            if !record.succeeded {
                self?.log.error("automation rule failed: exit \(outcome.exitCode), timedOut \(outcome.timedOut)")
            }
            Task { @MainActor in self?.appendRun(record) }
        }
    }

    private func appendRun(_ record: AutomationRunRecord) {
        runLog.insert(record, at: 0)
        if runLog.count > Self.maxLogEntries {
            runLog.removeLast(runLog.count - Self.maxLogEntries)
        }
    }
}
