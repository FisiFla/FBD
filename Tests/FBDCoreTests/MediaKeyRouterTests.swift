import CoreGraphics
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

    // MARK: - BetterDisplay target resolution (additive)

    private func candidate(
        id: CGDirectDisplayID,
        frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
        brightness: Bool = true,
        volume: Bool = true,
        main: Bool = false
    ) -> ScreenCandidate {
        ScreenCandidate(
            displayID: id,
            name: "Display",
            frame: frame,
            supportsBrightness: brightness,
            supportsVolume: volume,
            isMain: main,
            isOnline: true
        )
    }

    private func resolve(
        key: Int32,
        target: KeyboardControlTarget = .mouseScreen,
        candidates: [ScreenCandidate],
        mouse: CGPoint = CGPoint(x: 50, y: 50),
        systemVolume: Bool = false
    ) -> MediaKeyRouter.RoutedPress {
        MediaKeyRouter.resolve(
            keyCode: key,
            interceptEnabled: true,
            target: target,
            candidates: candidates,
            mouseLocation: mouse,
            focusedDisplayID: nil,
            audioDeviceName: nil,
            systemVolumeAvailable: systemVolume
        )
    }

    func testResolveBrightnessActsOnTheMouseScreen() {
        let press = resolve(key: brightnessUp, candidates: [candidate(id: 1, main: true)])
        XCTAssertEqual(press.decision.action, .brightnessUp)
        XCTAssertEqual(press.displayIDs, [1])
    }

    func testResolveVolumeUsesTheDisplayWhenItSupportsVolume() {
        let press = resolve(key: soundUp, candidates: [candidate(id: 1, volume: true)])
        XCTAssertEqual(press.decision.action, .volumeUp)
        XCTAssertEqual(press.decision.volumeTarget, .display)
        XCTAssertEqual(press.displayIDs, [1])
    }

    func testResolveVolumeFallsBackToTheSystemWhenTheDisplayHasNoVolume() {
        let press = resolve(key: soundUp, candidates: [candidate(id: 1, volume: false)], systemVolume: true)
        XCTAssertEqual(press.decision.action, .volumeUp)
        XCTAssertEqual(press.decision.volumeTarget, .system)
    }

    func testResolveVolumeWithNoPathAtAllPassesThrough() {
        let press = resolve(key: soundUp, candidates: [candidate(id: 1, volume: false)], systemVolume: false)
        XCTAssertEqual(press.decision.action, .none)
    }

    func testResolveUnknownKeyPassesThrough() {
        XCTAssertEqual(resolve(key: 99, candidates: [candidate(id: 1)]).decision.action, .none)
    }

    func testResolveEmptyCandidatesPassesThrough() {
        let press = resolve(key: brightnessUp, candidates: [])
        XCTAssertEqual(press.decision.action, .none)
        XCTAssertEqual(press.displayIDs, [])
    }

    func testResolveHonoursInterceptionDisabled() {
        let press = MediaKeyRouter.resolve(
            keyCode: brightnessUp,
            interceptEnabled: false,
            target: .mouseScreen,
            candidates: [candidate(id: 1)],
            mouseLocation: CGPoint(x: 50, y: 50),
            focusedDisplayID: nil,
            audioDeviceName: nil,
            systemVolumeAvailable: false
        )
        XCTAssertEqual(press.decision.action, .none)
    }

    func testResolveRoutesToTheFocusedScreen() {
        let press = MediaKeyRouter.resolve(
            keyCode: brightnessUp,
            interceptEnabled: true,
            target: .focusedScreen,
            candidates: [candidate(id: 1), candidate(id: 2, frame: CGRect(x: 200, y: 0, width: 100, height: 100))],
            mouseLocation: CGPoint(x: 50, y: 50),
            focusedDisplayID: 2,
            audioDeviceName: nil,
            systemVolumeAvailable: false
        )
        XCTAssertEqual(press.displayIDs, [2])
        XCTAssertEqual(press.decision.action, .brightnessUp)
    }
}
