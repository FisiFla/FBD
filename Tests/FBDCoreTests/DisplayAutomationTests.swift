import XCTest
@testable import FBDCore

/// Per-display automation: the pure decision layer plus the invocation shape.
///
/// Everything here is deliberately assertable **without starting a process** —
/// that is the point of the `AutomationExecuting` seam and of keeping
/// `AutomationScheduler` and `AutomationCommand` free of side effects.
final class DisplayAutomationTests: XCTestCase {

    private let limits = AutomationLimits(timeout: 10, minimumInterval: 5)

    private func rule(
        event: AutomationEvent = .displayConnected,
        identityKey: String = "vendor-model-serial",
        kind: AutomationActionKind = .shellScript,
        payload: String = "echo hi",
        enabled: Bool = true
    ) -> AutomationRule {
        AutomationRule(
            displayIdentityKey: identityKey,
            event: event,
            kind: kind,
            payload: payload,
            enabled: enabled
        )
    }

    private func now(_ offset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_000_000 + offset)
    }

    // MARK: - Tokens

    func testEventTokensRoundTrip() {
        for event in AutomationEvent.allCases {
            XCTAssertEqual(AutomationEvent(token: event.token), event)
        }
        // Case-insensitive, as a CLI should be.
        XCTAssertEqual(AutomationEvent(token: "CONNECT"), .displayConnected)
    }

    func testUnknownEventTokenIsRejected() {
        XCTAssertNil(AutomationEvent(token: "disconnect-yes"))
        XCTAssertNil(AutomationEvent(token: ""))
    }

    func testActionKindTokensRoundTrip() {
        for kind in AutomationActionKind.allCases {
            XCTAssertEqual(AutomationActionKind(token: kind.token), kind)
        }
        XCTAssertEqual(AutomationActionKind(token: "URL"), .url)
        XCTAssertNil(AutomationActionKind(token: "apple-script"))
    }

    func testSystemEventsAreClassified() {
        XCTAssertTrue(AutomationEvent.systemSleep.isSystemEvent)
        XCTAssertTrue(AutomationEvent.systemWake.isSystemEvent)
        XCTAssertFalse(AutomationEvent.displayConnected.isSystemEvent)
        XCTAssertFalse(AutomationEvent.displayDisconnected.isSystemEvent)
    }

    // MARK: - Matching

    func testAnyDisplayRuleMatchesEveryDisplay() {
        let any = rule(identityKey: "")
        XCTAssertTrue(any.matches(identityKey: "some-other-display"))
        XCTAssertTrue(any.matches(identityKey: "vendor-model-serial"))
    }

    func testDisplaySpecificRuleMatchesOnlyItsDisplay() {
        let specific = rule(identityKey: "vendor-model-serial")
        XCTAssertTrue(specific.matches(identityKey: "vendor-model-serial"))
        XCTAssertFalse(specific.matches(identityKey: "other"))
    }

    func testOnlyAnyDisplayRulesAnswerSystemEvents() {
        XCTAssertTrue(rule(identityKey: "").matches(identityKey: nil))
        // A rule addressed to one display must not fire on a system event —
        // a sleep cannot be attributed to a single display.
        XCTAssertFalse(rule(identityKey: "vendor-model-serial").matches(identityKey: nil))
    }

    // MARK: - Scheduling

    func testSchedulerHonoursEventDisplayAndEnabled() {
        let matching = rule()
        let wrongEvent = rule(event: .displayDisconnected)
        let wrongDisplay = rule(identityKey: "other")
        let disabled = rule(enabled: false)

        let due = AutomationScheduler.dueRules(
            [matching, wrongEvent, wrongDisplay, disabled],
            event: .displayConnected,
            identityKey: "vendor-model-serial",
            lastRun: [:],
            now: now(),
            limits: limits
        )
        XCTAssertEqual(due.map(\.id), [matching.id])
    }

    func testSchedulerRateLimitsRepeatedRuns() {
        let limited = rule()
        let recentlyRun = [limited.id: now()]

        let tooSoon = AutomationScheduler.dueRules(
            [limited], event: .displayConnected, identityKey: "vendor-model-serial",
            lastRun: recentlyRun, now: now(1), limits: limits
        )
        XCTAssertTrue(tooSoon.isEmpty, "a burst of topology events must not re-run the rule")

        let afterInterval = AutomationScheduler.dueRules(
            [limited], event: .displayConnected, identityKey: "vendor-model-serial",
            lastRun: recentlyRun, now: now(5), limits: limits
        )
        XCTAssertEqual(afterInterval.map(\.id), [limited.id])
    }

    func testSchedulerRateLimitIsPerRule() {
        let first = rule()
        let second = rule()
        let due = AutomationScheduler.dueRules(
            [first, second], event: .displayConnected, identityKey: "vendor-model-serial",
            lastRun: [first.id: now()], now: now(1), limits: limits
        )
        XCTAssertEqual(due.map(\.id), [second.id])
    }

    func testZeroMinimumIntervalDisablesTheRateLimit() {
        let immediately = AutomationLimits(timeout: 10, minimumInterval: 0)
        let only = rule()
        let due = AutomationScheduler.dueRules(
            [only], event: .displayConnected, identityKey: "vendor-model-serial",
            lastRun: [only.id: now()], now: now(), limits: immediately
        )
        XCTAssertEqual(due.map(\.id), [only.id])
    }

    // MARK: - Limits

    func testLimitsAreClamped() {
        XCTAssertEqual(AutomationLimits(timeout: 0).timeout, 1)
        XCTAssertEqual(AutomationLimits(timeout: 99_999).timeout, AutomationLimits.maxTimeout)
        XCTAssertEqual(AutomationLimits(minimumInterval: -5).minimumInterval, 0)
        XCTAssertEqual(
            AutomationLimits(minimumInterval: 99_999).minimumInterval,
            AutomationLimits.maxMinimumInterval
        )
    }

    // MARK: - Invocation (never starts anything)

    func testShellInvocationRunsThroughZsh() {
        let invocation = AutomationCommand.invocation(
            kind: .shellScript, payload: "echo hi", environment: ["FBD_EVENT": "displayConnected"]
        )
        XCTAssertEqual(invocation.executable, "/bin/zsh")
        XCTAssertEqual(invocation.arguments, ["-c", "echo hi"])
        XCTAssertEqual(invocation.environment["FBD_EVENT"], "displayConnected")
    }

    func testURLInvocationGoesThroughOpen() {
        let invocation = AutomationCommand.invocation(kind: .url, payload: "shortcuts://run-shortcut?name=X")
        XCTAssertEqual(invocation.executable, "/usr/bin/open")
        XCTAssertEqual(invocation.arguments, ["shortcuts://run-shortcut?name=X"])
    }

    func testEnvironmentDescribesTheTrigger() {
        let environment = AutomationCommand.environment(
            event: .displayDisconnected,
            displayIdentifier: "3",
            displayName: "Studio Display",
            displayIdentityKey: "1552-4131-1234"
        )
        XCTAssertEqual(environment["FBD_EVENT"], "displayDisconnected")
        XCTAssertEqual(environment["FBD_EVENT_LABEL"], "display disconnected")
        XCTAssertEqual(environment["FBD_DISPLAY_ID"], "3")
        XCTAssertEqual(environment["FBD_DISPLAY_NAME"], "Studio Display")
        XCTAssertEqual(environment["FBD_DISPLAY_IDENTITY"], "1552-4131-1234")
    }

    func testEnvironmentOmitsAbsentDisplayFields() {
        let environment = AutomationCommand.environment(event: .systemWake)
        XCTAssertEqual(environment["FBD_EVENT"], "systemWake")
        XCTAssertNil(environment["FBD_DISPLAY_ID"])
        XCTAssertNil(environment["FBD_DISPLAY_NAME"])
        XCTAssertNil(environment["FBD_DISPLAY_IDENTITY"])
    }

    // MARK: - Records and persistence

    func testRunRecordSuccessIsExitZeroAndNotTimedOut() {
        let ok = AutomationRunRecord(ruleID: UUID(), event: .systemWake, date: Date(), exitCode: 0, output: "", timedOut: false)
        XCTAssertTrue(ok.succeeded)
        let failed = AutomationRunRecord(ruleID: UUID(), event: .systemWake, date: Date(), exitCode: 1, output: "boom", timedOut: false)
        XCTAssertFalse(failed.succeeded)
        // A timed-out run is never a success, whatever the status says.
        let timedOut = AutomationRunRecord(ruleID: UUID(), event: .systemWake, date: Date(), exitCode: 0, output: "", timedOut: true)
        XCTAssertFalse(timedOut.succeeded)
    }

    func testRuleSurvivesACodableRoundTrip() throws {
        let original = rule(event: .systemSleep, identityKey: "", kind: .url, payload: "https://example.com")
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([AutomationRule].self, from: data)
        XCTAssertEqual(decoded, [original])
    }
}
