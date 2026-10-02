import XCTest
@testable import FBDCore

/// Tests for the base-M3 built-in-disconnect guard (waydabber/BetterDisplay#4723).
///
/// Only the pure decision functions are covered: `isAffectedHardware` probes the
/// running machine, and `DisconnectController.setEnabled` needs a real built-in
/// display — neither can be exercised in a unit test.
final class BuiltInDisconnectGuardTests: XCTestCase {

    // MARK: - Base-M3 chip identification

    func testBaseM3ChipIsRecognised() {
        XCTAssertTrue(BuiltInDisconnectGuard.isBaseM3Chip("Apple M3"))
    }

    func testM3ProMaxUltraAreNotBaseM3() {
        XCTAssertFalse(BuiltInDisconnectGuard.isBaseM3Chip("Apple M3 Pro"))
        XCTAssertFalse(BuiltInDisconnectGuard.isBaseM3Chip("Apple M3 Max"))
        XCTAssertFalse(BuiltInDisconnectGuard.isBaseM3Chip("Apple M3 Ultra"))
    }

    func testOtherChipFamiliesAreNotBaseM3() {
        XCTAssertFalse(BuiltInDisconnectGuard.isBaseM3Chip("Apple M1"))
        XCTAssertFalse(BuiltInDisconnectGuard.isBaseM3Chip("Apple M1 Max"))
        XCTAssertFalse(BuiltInDisconnectGuard.isBaseM3Chip("Apple M2"))
        XCTAssertFalse(BuiltInDisconnectGuard.isBaseM3Chip("Apple M4 Pro"))
        XCTAssertFalse(BuiltInDisconnectGuard.isBaseM3Chip("Intel(R) Core(TM) i7"))
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertTrue(BuiltInDisconnectGuard.isBaseM3Chip("  Apple M3 "))
        XCTAssertTrue(BuiltInDisconnectGuard.isBaseM3Chip("Apple M3\n"))
    }

    func testParenthesisedCoreCountSuffixIsIgnored() {
        XCTAssertTrue(BuiltInDisconnectGuard.isBaseM3Chip("Apple M3 (8-core)"))
        // …but the suffix must not turn a Pro/Max into a base M3.
        XCTAssertFalse(BuiltInDisconnectGuard.isBaseM3Chip("Apple M3 Pro (12-core)"))
    }

    func testEmptyOrUnknownBrandStringIsNotBaseM3() {
        XCTAssertFalse(BuiltInDisconnectGuard.isBaseM3Chip(""))
        XCTAssertFalse(BuiltInDisconnectGuard.isBaseM3Chip("arm64"))
    }

    // MARK: - The decision

    func testUnaffectedHardwareIsAlwaysAllowed() {
        XCTAssertTrue(BuiltInDisconnectGuard.allowsBuiltInDisconnect(affected: false, overrideEnabled: false))
        XCTAssertTrue(BuiltInDisconnectGuard.allowsBuiltInDisconnect(affected: false, overrideEnabled: true))
    }

    func testAffectedHardwareRefusesWithoutTheExplicitOverride() {
        XCTAssertFalse(BuiltInDisconnectGuard.allowsBuiltInDisconnect(affected: true, overrideEnabled: false))
    }

    func testAffectedHardwareAllowsWithTheExplicitOverride() {
        XCTAssertTrue(BuiltInDisconnectGuard.allowsBuiltInDisconnect(affected: true, overrideEnabled: true))
    }

    // MARK: - Ship-off default

    /// The override is an escape hatch, so it must not be on by default.
    func testOverrideDefaultsToOff() throws {
        let key = "allowBuiltInDisconnectOnAffectedMacs"
        guard Settings.defaults.object(forKey: key) == nil else {
            throw XCTSkip("\(key) already written in this defaults domain")
        }
        XCTAssertFalse(Settings.allowBuiltInDisconnectOnAffectedMacs)
    }
}
