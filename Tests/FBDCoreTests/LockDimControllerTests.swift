import XCTest
@testable import FBDCore

/// Lock/screensaver dimming: the pure decision machine, the policy persistence
/// round-trip, and the controller's effect + observer wiring. Hardware is never
/// touched — the controller is driven through a fake `LockDimApplying`.
final class LockDimControllerTests: XCTestCase {
    private let suiteName = "test.fbd.lockdim"
    private var fake: FakeBrightness!

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        fake = FakeBrightness()
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        fake = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeController(policy: LockDimPolicy? = nil) -> LockDimController {
        let controller = LockDimController(
            defaults: UserDefaults(suiteName: suiteName)!,
            applier: fake
        )
        if let policy { controller.savePolicy(policy) }
        return controller
    }

    private func enabled(_ target: Double) -> LockDimPolicy {
        LockDimPolicy(enabled: true, targetPercent: target)
    }

    /// A brightness seam that records every write instead of driving hardware.
    private final class FakeBrightness: LockDimApplying {
        var brightness: Double?
        private(set) var writes: [Double] = []

        init(brightness: Double? = nil) {
            self.brightness = brightness
        }

        func currentBrightness() -> Double? { brightness }

        func setBrightness(_ value: Double) {
            writes.append(value)
            brightness = value
        }
    }

    // MARK: - State machine: disabled policy

    func testDisabledPolicyIgnoresLock() {
        var machine = LockDimStateMachine()
        let action = machine.handle(
            .screenLocked,
            policy: LockDimPolicy(enabled: false, targetPercent: 20),
            currentBrightness: 0.5
        )
        XCTAssertEqual(action, .none)
        XCTAssertNil(machine.recordedBrightness)
    }

    func testDisabledPolicyIgnoresUnlock() {
        var machine = LockDimStateMachine()
        let action = machine.handle(
            .screenUnlocked,
            policy: LockDimPolicy(enabled: false, targetPercent: 20),
            currentBrightness: 0.5
        )
        XCTAssertEqual(action, .none)
    }

    func testDisabledPolicyNeverRecordsSoALaterEnabledUnlockIsNoOp() {
        var machine = LockDimStateMachine()
        _ = machine.handle(.screenLocked, policy: LockDimPolicy(enabled: false, targetPercent: 20), currentBrightness: 0.5)
        XCTAssertNil(machine.recordedBrightness, "a disabled policy must not leave a record behind")
        XCTAssertEqual(machine.handle(.screenUnlocked, policy: enabled(20), currentBrightness: 0.5), .none)
    }

    // MARK: - State machine: lock

    func testLockWithKnownBrightnessDimsToTarget() {
        var machine = LockDimStateMachine()
        XCTAssertEqual(
            machine.handle(.screenLocked, policy: enabled(20), currentBrightness: 0.8),
            .dim(to: 0.2)
        )
    }

    func testLockRecordsTheOriginalBrightnessForRestore() {
        var machine = LockDimStateMachine()
        _ = machine.handle(.screenLocked, policy: enabled(20), currentBrightness: 0.8)
        XCTAssertEqual(machine.recordedBrightness, 0.8)
        XCTAssertEqual(machine.handle(.screenUnlocked, policy: enabled(20), currentBrightness: 0.2), .restore(to: 0.8))
    }

    func testLockWithUnknownBrightnessDoesNotDim() {
        var machine = LockDimStateMachine()
        XCTAssertEqual(machine.handle(.screenLocked, policy: enabled(20), currentBrightness: nil), .none)
        XCTAssertNil(machine.recordedBrightness)
    }

    func testUnknownBrightnessLockRecordsNothingSoALaterKnownLockDimms() {
        var machine = LockDimStateMachine()
        _ = machine.handle(.screenLocked, policy: enabled(20), currentBrightness: nil)
        XCTAssertEqual(machine.handle(.screenLocked, policy: enabled(20), currentBrightness: 0.6), .dim(to: 0.2))
    }

    func testDoubleLockIsIdempotentAndKeepsTheOriginalBrightness() {
        var machine = LockDimStateMachine()
        _ = machine.handle(.screenLocked, policy: enabled(20), currentBrightness: 0.8)
        // A second lock — with a different current brightness — must not
        // overwrite the recorded original.
        XCTAssertEqual(machine.handle(.screenLocked, policy: enabled(50), currentBrightness: 0.1), .none)
        XCTAssertEqual(machine.recordedBrightness, 0.8)
        XCTAssertEqual(machine.handle(.screenUnlocked, policy: enabled(20), currentBrightness: 0.1), .restore(to: 0.8))
    }

    // MARK: - State machine: unlock

    func testUnlockRestoresExactRecordedValueThenClears() {
        var machine = LockDimStateMachine()
        _ = machine.handle(.screenLocked, policy: enabled(20), currentBrightness: 0.4)
        XCTAssertEqual(machine.handle(.screenUnlocked, policy: enabled(20), currentBrightness: 0.2), .restore(to: 0.4))
        XCTAssertNil(machine.recordedBrightness)
        // Nothing left to restore on a second unlock.
        XCTAssertEqual(machine.handle(.screenUnlocked, policy: enabled(20), currentBrightness: 0.4), .none)
    }

    func testUnlockWithNothingRecordedIsNoOp() {
        var machine = LockDimStateMachine()
        XCTAssertEqual(machine.handle(.screenUnlocked, policy: enabled(20), currentBrightness: 0.5), .none)
    }

    func testLockAfterRestoreDimmsAgain() {
        var machine = LockDimStateMachine()
        _ = machine.handle(.screenLocked, policy: enabled(20), currentBrightness: 0.4)
        _ = machine.handle(.screenUnlocked, policy: enabled(20), currentBrightness: 0.2)
        XCTAssertEqual(machine.handle(.screenLocked, policy: enabled(30), currentBrightness: 0.2), .dim(to: 0.3))
    }

    func testRestoreRecordedForcesValueAndClears() {
        var machine = LockDimStateMachine()
        _ = machine.handle(.screenLocked, policy: enabled(20), currentBrightness: 0.4)
        XCTAssertEqual(machine.restoreRecorded(), .restore(to: 0.4))
        XCTAssertNil(machine.recordedBrightness)
        XCTAssertEqual(machine.restoreRecorded(), .none)
    }

    // MARK: - Clamping

    func testClampedPolicyNormalisesTargetAboveHundred() {
        XCTAssertEqual(LockDimPolicy(enabled: true, targetPercent: 150).clamped().targetPercent, 100)
    }

    func testClampedPolicyNormalisesTargetBelowZero() {
        XCTAssertEqual(LockDimPolicy(enabled: true, targetPercent: -10).clamped().targetPercent, 0)
    }

    func testClampedPolicyKeepsAnInRangeTarget() {
        XCTAssertEqual(LockDimPolicy(enabled: true, targetPercent: 42.5).clamped().targetPercent, 42.5)
    }

    func testClampedPolicyNormalisesNaNTarget() {
        let clamped = LockDimPolicy(enabled: true, targetPercent: .nan).clamped()
        XCTAssertFalse(clamped.targetPercent.isNaN)
        XCTAssertEqual(clamped.targetPercent, 0)
    }

    func testDimValueIsPercentOverHundred() {
        XCTAssertEqual(LockDimPolicy(enabled: true, targetPercent: 25).dimValue, 0.25, accuracy: 1e-12)
    }

    // MARK: - Controller: effects through the fake

    func testControllerDimmsOnLockAndRestoresOnUnlockThroughTheFake() {
        fake.brightness = 0.7
        let controller = makeController(policy: enabled(20))
        controller.emit(.screenLocked)
        XCTAssertEqual(fake.writes, [0.2])
        controller.emit(.screenUnlocked)
        XCTAssertEqual(fake.writes, [0.2, 0.7])
        XCTAssertEqual(fake.brightness ?? .nan, 0.7, accuracy: 1e-12)
    }

    func testControllerDisabledPolicyNeverTouchesBrightness() {
        fake.brightness = 0.7
        let controller = makeController(policy: LockDimPolicy(enabled: false, targetPercent: 20))
        controller.emit(.screenLocked)
        controller.emit(.screenUnlocked)
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertEqual(fake.brightness, 0.7)
    }

    func testControllerLockWithUnknownBrightnessDoesNotWrite() {
        fake.brightness = nil
        let controller = makeController(policy: enabled(10))
        controller.emit(.screenLocked)
        XCTAssertTrue(fake.writes.isEmpty, "must never dim blind")
    }

    func testControllerRestoresALeftoverDimWhenPolicyIsOff() {
        fake.brightness = 0.9
        let controller = makeController(policy: enabled(10))
        controller.emit(.screenLocked)
        XCTAssertEqual(fake.brightness ?? .nan, 0.1, accuracy: 1e-12)
        // The user switches the policy off while still locked.
        controller.savePolicy(LockDimPolicy(enabled: false, targetPercent: 10))
        controller.emit(.screenUnlocked)
        XCTAssertEqual(fake.brightness ?? .nan, 0.9, accuracy: 1e-12, "a disabled policy must never leave the screen dimmed")
    }

    func testStopRestoresARecordedBrightness() {
        fake.brightness = 0.9
        let controller = makeController(policy: enabled(10))
        controller.start()
        controller.emit(.screenLocked)
        XCTAssertEqual(fake.brightness ?? .nan, 0.1, accuracy: 1e-12)
        controller.stop()
        XCTAssertEqual(fake.brightness ?? .nan, 0.9, accuracy: 1e-12)
    }

    func testStartIsIdempotent() {
        let controller = makeController()
        controller.start()
        XCTAssertEqual(controller.registeredObserverCount, 2)
        controller.start()
        XCTAssertEqual(controller.registeredObserverCount, 2, "a second start() must not double-register")
        controller.stop()
        XCTAssertEqual(controller.registeredObserverCount, 0)
    }

    // MARK: - Policy persistence

    func testPolicyDefaultsWhenUnset() {
        XCTAssertEqual(
            makeController().loadPolicy(),
            LockDimPolicy(enabled: false, targetPercent: LockDimPolicy.defaultTargetPercent)
        )
    }

    func testPolicyRoundTripThroughScratchSuite() {
        makeController().savePolicy(LockDimPolicy(enabled: true, targetPercent: 42))
        let fresh = LockDimController(defaults: UserDefaults(suiteName: suiteName)!, applier: fake)
        XCTAssertEqual(fresh.loadPolicy(), LockDimPolicy(enabled: true, targetPercent: 42))
    }

    func testPolicySaveClampsOutOfRangeTarget() {
        let controller = makeController()
        controller.savePolicy(LockDimPolicy(enabled: true, targetPercent: 150))
        XCTAssertEqual(controller.loadPolicy().targetPercent, 100)
        controller.savePolicy(LockDimPolicy(enabled: true, targetPercent: -30))
        XCTAssertEqual(controller.loadPolicy().targetPercent, 0)
    }

    func testPolicyStaysOutOfStandardDefaults() {
        makeController().savePolicy(LockDimPolicy(enabled: true, targetPercent: 33))
        XCTAssertNotNil(UserDefaults(suiteName: suiteName)?.object(forKey: "lockDimTargetPercent"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "lockDimTargetPercent"), "must not write to UserDefaults.standard")
    }
}
