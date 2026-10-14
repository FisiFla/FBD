import XCTest
@testable import FBDCore

/// Pure startup-safe-mode logic: the Shift modifier bit, the `FBD_SAFE_MODE`
/// environment form, and the single inverse predicate the app gates stored-state
/// applies on. No hardware, no AppKit.
final class SafeModeTests: XCTestCase {

    // MARK: - Shift modifier bit

    func testShiftModifierRequestsSafeMode() {
        XCTAssertTrue(SafeMode.isRequested(modifierFlags: SafeMode.shiftModifierMask, environment: [:]))
    }

    func testNoModifierDoesNotRequestSafeMode() {
        XCTAssertFalse(SafeMode.isRequested(modifierFlags: 0, environment: [:]))
    }

    func testUnrelatedModifierDoesNotRequestSafeMode() {
        // Command is 1 << 20; held without Shift it must not request safe mode.
        XCTAssertFalse(SafeMode.isRequested(modifierFlags: 1 << 20, environment: [:]))
    }

    func testShiftAmongOtherModifiersRequestsSafeMode() {
        let shiftAndCommand = SafeMode.shiftModifierMask | (1 << 20)
        XCTAssertTrue(SafeMode.isRequested(modifierFlags: shiftAndCommand, environment: [:]))
    }

    // MARK: - Environment form

    func testEnvironmentTruthyValuesRequestSafeMode() {
        for value in ["1", "true", "TRUE", "True", "yes", "Yes", "YES"] {
            XCTAssertTrue(
                SafeMode.isRequested(modifierFlags: 0, environment: ["FBD_SAFE_MODE": value]),
                "FBD_SAFE_MODE=\(value) must request safe mode"
            )
        }
    }

    func testEnvironmentFalsyOrAbsentDoesNotRequestSafeMode() {
        for value in ["0", "false", "FALSE", "no", "", "2"] {
            XCTAssertFalse(
                SafeMode.isRequested(modifierFlags: 0, environment: ["FBD_SAFE_MODE": value]),
                "FBD_SAFE_MODE=\(value) must not request safe mode"
            )
        }
        XCTAssertFalse(SafeMode.isRequested(modifierFlags: 0, environment: [:]), "absent must not request safe mode")
        XCTAssertFalse(
            SafeMode.isRequested(modifierFlags: 0, environment: ["SOMETHING_ELSE": "true"]),
            "an unrelated environment variable must not request safe mode"
        )
    }

    func testShiftAndEnvironmentTogetherRequestSafeMode() {
        XCTAssertTrue(SafeMode.isRequested(
            modifierFlags: SafeMode.shiftModifierMask,
            environment: ["FBD_SAFE_MODE": "yes"]
        ))
    }

    // MARK: - shouldApplyStoredState (the inverse predicate)

    func testShouldApplyStoredStateWhenSafeModeNotRequested() {
        XCTAssertTrue(SafeMode.shouldApplyStoredState(readFromEnvironment: [:]))
        XCTAssertTrue(SafeMode.shouldApplyStoredState(modifierFlags: 0, readFromEnvironment: [:]))
    }

    func testShouldNotApplyStoredStateWhenShiftHeld() {
        XCTAssertFalse(SafeMode.shouldApplyStoredState(
            modifierFlags: SafeMode.shiftModifierMask,
            readFromEnvironment: [:]
        ))
    }

    func testShouldNotApplyStoredStateWhenEnvironmentRequests() {
        XCTAssertFalse(SafeMode.shouldApplyStoredState(readFromEnvironment: ["FBD_SAFE_MODE": "1"]))
        XCTAssertFalse(SafeMode.shouldApplyStoredState(readFromEnvironment: ["FBD_SAFE_MODE": "true"]))
    }

    func testShouldApplyStoredStateIsExactlyTheInverseOfIsRequested() {
        let environments: [[String: String]] = [[:], ["FBD_SAFE_MODE": "1"], ["FBD_SAFE_MODE": "no"]]
        let flags: [UInt] = [0, SafeMode.shiftModifierMask, 1 << 20]
        for modifierFlags in flags {
            for environment in environments {
                XCTAssertEqual(
                    SafeMode.shouldApplyStoredState(modifierFlags: modifierFlags, readFromEnvironment: environment),
                    !SafeMode.isRequested(modifierFlags: modifierFlags, environment: environment),
                    "inverse must hold for flags \(modifierFlags), env \(environment)"
                )
            }
        }
    }

    // MARK: - Constants

    func testShiftModifierMaskIsAppKitShiftBit() {
        XCTAssertEqual(SafeMode.shiftModifierMask, 1 << 17)
    }

    func testEnvironmentKeyIsFbdSafeMode() {
        XCTAssertEqual(SafeMode.environmentKey, "FBD_SAFE_MODE")
    }
}
