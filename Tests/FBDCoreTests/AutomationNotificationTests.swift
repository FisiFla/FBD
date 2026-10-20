import XCTest
@testable import FBDCore

/// Manual controls and the notification action.
///
/// The manual-invocation event exists to be run by the user, and the notification
/// action starts nothing — both are properties worth locking, because each is a
/// guarantee rather than a behaviour: a manual control must never be selected by
/// the scheduler, and a notification must never be mistaken for a process.
final class AutomationManualControlTests: XCTestCase {
    // MARK: - Tokens

    func testNewTokensRoundTrip() {
        XCTAssertEqual(AutomationEvent(token: "manual"), .manual)
        XCTAssertEqual(AutomationActionKind(token: "notify"), .notification)
        XCTAssertEqual(AutomationEvent.manual.token, "manual")
        XCTAssertEqual(AutomationActionKind.notification.token, "notify")
    }

    /// The CLI derives its help and its refusal messages from these, so a token
    /// that stops round-tripping would advertise something unusable.
    func testEveryTokenStillRoundTrips() {
        for event in AutomationEvent.allCases {
            XCTAssertEqual(AutomationEvent(token: event.token), event, "event token \(event.token)")
        }
        for kind in AutomationActionKind.allCases {
            XCTAssertEqual(AutomationActionKind(token: kind.token), kind, "kind token \(kind.token)")
        }
    }

    /// A manual event belongs to no display and to no system transition.
    func testManualIsNotASystemEvent() {
        XCTAssertFalse(AutomationEvent.manual.isSystemEvent)
        XCTAssertFalse(AutomationEvent.manual.label.isEmpty)
    }

    // MARK: - The scheduler never selects a manual control

    func testSchedulerRefusesTheManualEventEntirely() {
        let manual = AutomationRule(
            displayIdentityKey: "", event: .manual, kind: .shellScript, payload: "echo hi"
        )
        // `dueRules` is asked *for* the manual event here and still returns
        // nothing: selecting a manual control on a tick would let an event storm
        // run the user's commands unbidden, so the guard is on the event itself
        // rather than on the rule.
        XCTAssertTrue(
            AutomationScheduler.dueRules(
                [manual],
                event: .manual,
                identityKey: nil,
                lastRun: [:],
                now: Date(timeIntervalSince1970: 1_000_000),
                limits: AutomationLimits()
            ).isEmpty
        )
    }

    func testSchedulerIgnoresAManualRuleForARealEvent() {
        let manual = AutomationRule(
            displayIdentityKey: "", event: .manual, kind: .shellScript, payload: "echo hi"
        )
        XCTAssertTrue(
            AutomationScheduler.dueRules(
                [manual],
                event: .displayConnected,
                identityKey: "1-2-3",
                lastRun: [:],
                now: Date(timeIntervalSince1970: 1_000_000),
                limits: AutomationLimits()
            ).isEmpty
        )
    }

    // MARK: - Notification payload

    /// `notify "Coffee brewed"` should do the obvious thing rather than demand a
    /// separator nobody asked for.
    func testPayloadWithoutASeparatorIsTheWholeBody() {
        let parsed = AutomationNotification.parse("Coffee brewed")
        XCTAssertEqual(parsed.title, "FBD")
        XCTAssertEqual(parsed.body, "Coffee brewed")
    }

    func testPayloadSplitsOnTheFirstSeparatorOnly() {
        let parsed = AutomationNotification.parse("  Display  |  left | right  ")
        XCTAssertEqual(parsed.title, "Display")
        XCTAssertEqual(parsed.body, "left | right")
    }

    func testAnEmptyTitleFallsBack() {
        XCTAssertEqual(AutomationNotification.parse("  | body").title, "FBD")
        XCTAssertEqual(AutomationNotification.parse("  | body").body, "body")
    }

    // MARK: - Effect resolution

    func testANotificationResolvesToANotificationAndBuildsNoInvocation() {
        XCTAssertEqual(
            AutomationCommand.effect(kind: .notification, payload: "Title | Body"),
            .notify(title: "Title", body: "Body")
        )
        XCTAssertNil(
            AutomationCommand.invocation(kind: .notification, payload: "x"),
            "a notification has no process, so there is no invocation to build"
        )
    }

    func testProcessKindsStillResolveToInvocations() {
        XCTAssertEqual(
            AutomationCommand.effect(kind: .shellScript, payload: "echo hi", environment: ["A": "B"]),
            .run(AutomationInvocation(
                executable: "/bin/zsh", arguments: ["-c", "echo hi"], environment: ["A": "B"]
            ))
        )
        XCTAssertEqual(
            AutomationCommand.effect(kind: .url, payload: "https://example.com"),
            .run(AutomationInvocation(
                executable: "/usr/bin/open", arguments: ["https://example.com"], environment: [:]
            ))
        )
    }
}

/// Delivery, with both seams faked: no process is started and no notification
/// reaches the screen.
@MainActor
final class AutomationNotificationDeliveryTests: XCTestCase {
    /// `@unchecked Sendable`: the seams require `Sendable` because the controller
    /// calls them from its serial queue, and a fake that records what happened is
    /// exactly the case the check cannot decide mechanically. Nothing here is
    /// reached from two threads — these tests are single-threaded.
    private final class FakeExecutor: AutomationExecuting, @unchecked Sendable {
        var ran: [AutomationInvocation] = []
        func execute(
            _ invocation: AutomationInvocation,
            timeout: TimeInterval
        ) -> (exitCode: Int32, output: String, timedOut: Bool) {
            ran.append(invocation)
            return (0, "process ran", false)
        }
    }

    private final class FakeNotifier: AutomationNotifying, @unchecked Sendable {
        var delivered: [(title: String, body: String)] = []
        var delivers = true
        func deliver(title: String, body: String) -> Bool {
            delivered.append((title, body))
            return delivers
        }
    }

    private func rule(kind: AutomationActionKind, payload: String) -> AutomationRule {
        AutomationRule(displayIdentityKey: "", event: .manual, kind: kind, payload: payload)
    }

    func testANotificationDeliversAndIsRecorded() {
        let executor = FakeExecutor()
        let notifier = FakeNotifier()
        let controller = DisplayAutomationController(executor: executor, notifier: notifier)

        let record = controller.runSynchronously(rule(kind: .notification, payload: "Coffee | brewed"))

        XCTAssertEqual(notifier.delivered.count, 1)
        XCTAssertEqual(notifier.delivered.first?.title, "Coffee")
        XCTAssertEqual(notifier.delivered.first?.body, "brewed")
        XCTAssertEqual(record.exitCode, 0)
        XCTAssertEqual(record.output, "notification handed to Notification Centre: Coffee")
        XCTAssertTrue(record.succeeded)
        XCTAssertTrue(executor.ran.isEmpty, "a notification action must not start a process")
    }

    /// A notification that could not be handed over must not look like a success.
    func testAnUndeliverableNotificationIsReported() {
        let notifier = FakeNotifier()
        notifier.delivers = false
        let controller = DisplayAutomationController(executor: FakeExecutor(), notifier: notifier)

        let record = controller.runSynchronously(rule(kind: .notification, payload: "Body only"))

        XCTAssertEqual(record.exitCode, 1)
        XCTAssertEqual(record.output, "notification could not be handed to Notification Centre")
        XCTAssertFalse(record.succeeded)
    }

    func testAProcessRuleStillGoesThroughTheExecutor() {
        let executor = FakeExecutor()
        let controller = DisplayAutomationController(executor: executor, notifier: FakeNotifier())

        let record = controller.runSynchronously(rule(kind: .shellScript, payload: "echo hi"))

        XCTAssertEqual(executor.ran.count, 1)
        XCTAssertEqual(executor.ran.first?.executable, "/bin/zsh")
        XCTAssertEqual(record.output, "process ran")
    }
}
