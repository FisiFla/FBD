import CoreGraphics
import XCTest
@testable import FBDCore

/// Controller-level tests for `DisconnectController.apply(_:)`.
///
/// The display IDs used here are deliberately not real, so the underlying CGS
/// calls fail and the controller must *degrade* (skip the step, return a count)
/// rather than crash. Real topology changes need attached hardware and are out
/// of scope for a unit test.
final class DisconnectControllerTests: XCTestCase {

    /// A display ID that will not resolve to a connected display.
    private let unknownA: CGDirectDisplayID = 424242
    private let unknownB: CGDirectDisplayID = 424243

    func testApplyEmptyPlanReturnsZero() {
        let controller = DisconnectController()
        XCTAssertEqual(controller.apply([]), 0)
    }

    func testApplyReturnsZeroWhenEveryStepIsRefused() {
        let controller = DisconnectController()
        let plan = [
            ConnectionStep(displayID: unknownA, enable: true, reason: "connect unknown"),
            ConnectionStep(displayID: unknownB, enable: false, reason: "disconnect unknown"),
        ]
        XCTAssertEqual(controller.apply(plan), 0)
    }

    func testApplyDoesNotThrowOnUnknownDisplays() {
        let controller = DisconnectController()
        // Exercising both a connect and a disconnect of an unknown display must
        // not trap — the worst case is a refused step.
        let count = controller.apply([
            ConnectionStep(displayID: unknownA, enable: true, reason: "enable"),
            ConnectionStep(displayID: unknownA, enable: false, reason: "disable"),
        ])
        XCTAssertGreaterThanOrEqual(count, 0)
        XCTAssertLessThanOrEqual(count, 2)
    }

    func testApplyCountNeverExceedsStepCount() {
        let controller = DisconnectController()
        let plan = (0..<5).map {
            ConnectionStep(
                displayID: CGDirectDisplayID(500000 + $0),
                enable: $0.isMultiple(of: 2),
                reason: "step \($0)"
            )
        }
        let applied = controller.apply(plan)
        XCTAssertGreaterThanOrEqual(applied, 0)
        XCTAssertLessThanOrEqual(applied, plan.count)
    }

    func testApplyWithUnknownDisableStepIsRefused() {
        let controller = DisconnectController()
        let applied = controller.apply([
            ConnectionStep(displayID: unknownB, enable: false, reason: "disconnect unknown"),
        ])
        XCTAssertEqual(applied, 0)
    }

    func testApplyReturnsIntAndIsDiscardable() {
        let controller = DisconnectController()
        // The return value is informational; calling for effect alone must compile.
        controller.apply([ConnectionStep(displayID: unknownA, enable: true, reason: "enable")])
    }

    func testBuiltInDisabledFlagPersistsAcrossInstances() {
        let suite = "test.fbd.disconnect"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = DisconnectController(defaults: defaults)
        XCTAssertFalse(first.builtInDisabledByUs)
        first.builtInDisabledByUs = true

        XCTAssertTrue(DisconnectController(defaults: defaults).builtInDisabledByUs)
    }
}
