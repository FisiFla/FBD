import XCTest
@testable import FBDCore

/// The volume half of the media-key routing matrix, extended for the Mac's own
/// output path (#20).
///
/// The pre-existing `MediaKeyRouterTests` matrix still covers the original
/// behaviour — including that the action-only `route` wrapper is unchanged —
/// because `route` now delegates to `decide(systemVolumeAvailable: false)`.
/// These tests cover what the new route adds.
final class MediaKeySystemVolumeTests: XCTestCase {

    private let soundUp: Int32 = 0
    private let soundDown: Int32 = 1
    private let mute: Int32 = 7
    private let brightnessUp: Int32 = 2

    private func decide(
        _ keyCode: Int32,
        hasControlPath: Bool = true,
        hasDDC: Bool,
        systemVolume: Bool
    ) -> MediaKeyRouter.Decision {
        MediaKeyRouter.decide(
            keyCode: keyCode,
            interceptEnabled: true,
            targetHasControlPath: hasControlPath,
            targetHasDDC: hasDDC,
            systemVolumeAvailable: systemVolume
        )
    }

    // MARK: - The new fallback

    func testVolumeKeysFallBackToTheSystemWhenTheDisplayHasNoDDC() {
        // Before #20 a display without DDC meant the key passed through to
        // macOS. Now it moves the Mac's own output, which is what the user
        // pressing F11 on such a setup expects.
        for key in [soundUp, soundDown, mute] {
            let decision = decide(key, hasDDC: false, systemVolume: true)
            XCTAssertNotEqual(decision.action, .none, "key \(key) should be consumed")
            XCTAssertEqual(decision.volumeTarget, .system)
        }
    }

    func testVolumeKeysStillPassThroughWhenNeitherPathExists() {
        for key in [soundUp, soundDown, mute] {
            let decision = decide(key, hasDDC: false, systemVolume: false)
            XCTAssertEqual(decision.action, .none)
            XCTAssertNil(decision.volumeTarget)
        }
    }

    func testDDCIsPreferredOverTheSystemWhenBothAreAvailable() {
        // The key is about the display the user is looking at, so the display
        // wins; the system path is only a fallback.
        let decision = decide(soundUp, hasDDC: true, systemVolume: true)
        XCTAssertEqual(decision.action, .volumeUp)
        XCTAssertEqual(decision.volumeTarget, .display)
    }

    func testActionsAreTheSameShapeOnEitherPath() {
        // Only the target differs, so the controller's switch stays small.
        XCTAssertEqual(decide(soundUp, hasDDC: false, systemVolume: true).action, .volumeUp)
        XCTAssertEqual(decide(soundDown, hasDDC: false, systemVolume: true).action, .volumeDown)
        XCTAssertEqual(decide(mute, hasDDC: false, systemVolume: true).action, .toggleMute)
    }

    // MARK: - Brightness is unaffected

    func testBrightnessKeysCarryNoVolumeTarget() {
        // The system volume path must not leak into brightness routing.
        let decision = decide(brightnessUp, hasDDC: false, systemVolume: true)
        XCTAssertEqual(decision.action, .brightnessUp)
        XCTAssertNil(decision.volumeTarget)
    }

    // MARK: - The existing gates still hold

    func testInterceptionOffPassesEverythingThrough() {
        let decision = MediaKeyRouter.decide(
            keyCode: soundUp,
            interceptEnabled: false,
            targetHasControlPath: true,
            targetHasDDC: false,
            systemVolumeAvailable: true
        )
        XCTAssertEqual(decision.action, .none)
    }

    func testNoControlPathOnTheTargetStillPassesEverythingThrough() {
        let decision = decide(soundUp, hasControlPath: false, hasDDC: false, systemVolume: true)
        XCTAssertEqual(decision.action, .none)
    }

    func testUnknownKeysStillPassThrough() {
        XCTAssertEqual(decide(99, hasDDC: true, systemVolume: true).action, .none)
    }

    // MARK: - The action-only wrapper is unchanged

    func testRouteWrapperStillRequiresDDCForVolume() {
        // Back-compat pin: `route` reports no system path, so its behaviour is
        // exactly what it was before #20.
        XCTAssertEqual(
            MediaKeyRouter.route(
                keyCode: soundUp, interceptEnabled: true, targetHasControlPath: true, targetHasDDC: false
            ),
            .none
        )
        XCTAssertEqual(
            MediaKeyRouter.route(
                keyCode: soundUp, interceptEnabled: true, targetHasControlPath: true, targetHasDDC: true
            ),
            .volumeUp
        )
    }
}
