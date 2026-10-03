import XCTest
@testable import FBDCore

/// The VRR / ProMotion / min-refresh **label** formatter.
///
/// Deliberately limited to the pure layer. The SkyLight queries behind it
/// (`SkyLightAPI.modeCapabilities`) need a live WindowServer connection and
/// crash a process that lacks one — observed as a signal 11 in xctest — so they
/// must never be exercised from a test. Anything that calls them belongs on an
/// on-demand path, which is why the app queries them per `info` command rather
/// than storing capabilities on every `DisplayMode`.
final class ModeCapabilityLabelTests: XCTestCase {

    func testNothingReportedIsAnEmptyLabel() {
        // Not "no vrr": a display that answers nothing has told us nothing, and
        // printing a negative would be an assertion we cannot back up.
        XCTAssertEqual(
            SkyLightAPI.capabilityLabel(minRefreshRate: 0, isVRR: false, isProMotion: false),
            ""
        )
    }

    func testProMotionAlone() {
        XCTAssertEqual(
            SkyLightAPI.capabilityLabel(minRefreshRate: 120, isVRR: false, isProMotion: true),
            "proMotion"
        )
    }

    func testVRRWithAKnownRangeShowsBothEnds() {
        XCTAssertEqual(
            SkyLightAPI.capabilityLabel(
                minRefreshRate: 48, isVRR: true, isProMotion: false, maxRefreshRate: 120
            ),
            "vrr 48-120Hz"
        )
    }

    func testVRRWithNoKnownMaximumOmitsTheRange() {
        // Better to say "vrr" than to invent an upper bound.
        XCTAssertEqual(
            SkyLightAPI.capabilityLabel(minRefreshRate: 48, isVRR: true, isProMotion: false),
            "vrr"
        )
    }

    func testMinimumWithoutVRRIsReportedOnItsOwn() {
        XCTAssertEqual(
            SkyLightAPI.capabilityLabel(minRefreshRate: 48, isVRR: false, isProMotion: false),
            "min 48Hz"
        )
    }

    func testProMotionAndVRRTogether() {
        XCTAssertEqual(
            SkyLightAPI.capabilityLabel(
                minRefreshRate: 48, isVRR: true, isProMotion: true, maxRefreshRate: 120
            ),
            "proMotion vrr 48-120Hz"
        )
    }
}
