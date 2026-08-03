import XCTest
@testable import FBDCore

final class MediaKeyRouterTests: XCTestCase {
    // NX_KEYTYPE codes
    private let soundUp: Int32 = 0
    private let soundDown: Int32 = 1
    private let brightnessUp: Int32 = 2
    private let brightnessDown: Int32 = 3
    private let mute: Int32 = 7

    func testInterceptionDisabledPassesEverythingThrough() {
        for key in [soundUp, soundDown, brightnessUp, brightnessDown, mute, 99] {
            XCTAssertEqual(
                MediaKeyRouter.route(
                    keyCode: key,
                    interceptEnabled: false,
                    targetHasControlPath: true,
                    targetHasDDC: true
                ),
                .none,
                "key \(key) must pass through when interception is disabled"
            )
        }
    }

    func testNoControlPathPassesEverythingThrough() {
        for key in [soundUp, brightnessUp, mute] {
            XCTAssertEqual(
                MediaKeyRouter.route(
                    keyCode: key,
                    interceptEnabled: true,
                    targetHasControlPath: false,
                    targetHasDDC: false
                ),
                .none,
                "key \(key) must pass through when the target has no control path"
            )
        }
    }

    func testBrightnessKeysConsumedWithApplePath() {
        XCTAssertEqual(route(key: brightnessUp, control: true, ddc: false), .brightnessUp)
        XCTAssertEqual(route(key: brightnessDown, control: true, ddc: false), .brightnessDown)
    }

    func testBrightnessKeysConsumedWithDDCOnlyPath() {
        // DDC brightness is a valid route for the brightness keys.
        XCTAssertEqual(route(key: brightnessUp, control: true, ddc: true), .brightnessUp)
        XCTAssertEqual(route(key: brightnessDown, control: true, ddc: true), .brightnessDown)
    }

    func testVolumeKeysNeedDDC() {
        XCTAssertEqual(route(key: soundUp, control: true, ddc: true), .volumeUp)
        XCTAssertEqual(route(key: soundDown, control: true, ddc: true), .volumeDown)
        XCTAssertEqual(route(key: mute, control: true, ddc: true), .toggleMute)
        // Apple-only displays have no DDC volume — keys must pass through.
        XCTAssertEqual(route(key: soundUp, control: true, ddc: false), .none)
        XCTAssertEqual(route(key: soundDown, control: true, ddc: false), .none)
        XCTAssertEqual(route(key: mute, control: true, ddc: false), .none)
    }

    func testUnknownKeysPassThrough() {
        XCTAssertEqual(route(key: 99, control: true, ddc: true), .none)
        XCTAssertEqual(route(key: -1, control: true, ddc: true), .none)
    }

    func testStepMatchesMacOSStandard() {
        XCTAssertEqual(MediaKeyRouter.step, 0.0625)
    }

    private func route(key: Int32, control: Bool, ddc: Bool) -> MediaKeyAction {
        MediaKeyRouter.route(
            keyCode: key,
            interceptEnabled: true,
            targetHasControlPath: control,
            targetHasDDC: ddc
        )
    }
}
