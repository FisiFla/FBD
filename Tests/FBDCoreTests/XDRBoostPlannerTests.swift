import XCTest
import FBDCore

/// Tests for the XDR boost planner — the pure decision logic behind the
/// combined slider and the explicit `xdr` command. Locks the macOS 27
/// fallback chain and the below-ceiling overlay-stop rule (regression
/// coverage for the cycle-21 fixes).
final class XDRBoostPlannerTests: XCTestCase {
    // XDR scenario: 500-nit hardware ceiling, 1600-nit combined top.
    private let hardware = 500
    private let maxNits = 1600

    // MARK: - Slider planning

    func testBelowCeilingAlwaysPlansHardwareAndStopsOverlay() {
        // 20% of 1600 = 320 nits <= 500.
        XCTAssertEqual(
            XDRBoostPlanner.plan(value: 0.2, maxNits: maxNits, hardwareMaxNits: hardware, nativeAvailable: true, softwareEnabled: true),
            .hardware(fraction: 0.64) // 320 / 500
        )
        // Even with native + software both available, below-ceiling is hardware.
        XCTAssertEqual(
            XDRBoostPlanner.plan(value: 0.2, maxNits: maxNits, hardwareMaxNits: hardware, nativeAvailable: false, softwareEnabled: false),
            .hardware(fraction: 0.64)
        )
    }

    func testAboveCeilingPrefersNativeWhenAvailable() {
        XCTAssertEqual(
            XDRBoostPlanner.plan(value: 0.8, maxNits: maxNits, hardwareMaxNits: hardware, nativeAvailable: true, softwareEnabled: true),
            .nativeUpscale(nits: 1280)
        )
    }

    func testAboveCeilingFallsBackToSoftwareWhenNativeUnavailable() {
        XCTAssertEqual(
            XDRBoostPlanner.plan(value: 0.8, maxNits: maxNits, hardwareMaxNits: hardware, nativeAvailable: false, softwareEnabled: true),
            .softwareBoost(factor: 1280.0 / 500.0)
        )
    }

    func testAboveCeilingFailsWhenBothUnavailable() {
        XCTAssertEqual(
            XDRBoostPlanner.plan(value: 0.8, maxNits: maxNits, hardwareMaxNits: hardware, nativeAvailable: false, softwareEnabled: false),
            .fail
        )
    }

    func testNativeUnavailableWithSoftwareStillPrefersHardwareBelowCeiling() {
        // 30% of 1600 = 480 <= 500: hardware even though native is blocked.
        XCTAssertEqual(
            XDRBoostPlanner.plan(value: 0.3, maxNits: maxNits, hardwareMaxNits: hardware, nativeAvailable: false, softwareEnabled: true),
            .hardware(fraction: 0.96)
        )
    }

    func testNoHeadroomConfigStaysHardware() {
        XCTAssertEqual(
            XDRBoostPlanner.plan(value: 1, maxNits: 500, hardwareMaxNits: 500, nativeAvailable: true, softwareEnabled: true),
            .hardware(fraction: 1)
        )
    }

    func testZeroCeilingsFail() {
        XCTAssertEqual(
            XDRBoostPlanner.plan(value: 0.5, maxNits: 0, hardwareMaxNits: 500, nativeAvailable: true, softwareEnabled: true),
            .fail
        )
    }

    // MARK: - Explicit nits planning (the `xdr <id> <nits>` command)

    func testExplicitNitsPrefersNative() {
        XCTAssertEqual(
            XDRBoostPlanner.plan(nits: 800, hardwareMaxNits: hardware, nativeAvailable: true, softwareEnabled: false),
            .nativeUpscale(nits: 800)
        )
    }

    func testExplicitNitsFallsBackToSoftware() {
        XCTAssertEqual(
            XDRBoostPlanner.plan(nits: 800, hardwareMaxNits: hardware, nativeAvailable: false, softwareEnabled: true),
            .softwareBoost(factor: 800.0 / 500.0)
        )
    }

    func testExplicitNitsFailsWithoutSoftware() {
        XCTAssertEqual(
            XDRBoostPlanner.plan(nits: 800, hardwareMaxNits: hardware, nativeAvailable: false, softwareEnabled: false),
            .fail
        )
    }

    func testExplicitNitsBelowCeilingFails() {
        // A nits target at/below the hardware ceiling is not an upscale.
        XCTAssertEqual(
            XDRBoostPlanner.plan(nits: 300, hardwareMaxNits: hardware, nativeAvailable: false, softwareEnabled: true),
            .fail
        )
    }

    func testExplicitNonPositiveNitsFails() {
        XCTAssertEqual(
            XDRBoostPlanner.plan(nits: 0, hardwareMaxNits: hardware, nativeAvailable: true, softwareEnabled: true),
            .fail
        )
    }
}
