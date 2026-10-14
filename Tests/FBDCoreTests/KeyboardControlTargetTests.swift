import CoreGraphics
import XCTest
@testable import FBDCore

/// Pure tests for `KeyboardControlTarget`, `ScreenCandidate` and
/// `KeyboardControlResolver` — BetterDisplay parity for "which screen do the
/// keyboard brightness/volume keys act on".
final class KeyboardControlTargetTests: XCTestCase {

    // MARK: - Helpers

    private func candidate(
        id: CGDirectDisplayID,
        name: String = "Display",
        frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
        brightness: Bool = true,
        volume: Bool = true,
        main: Bool = false,
        online: Bool = true
    ) -> ScreenCandidate {
        ScreenCandidate(
            displayID: id,
            name: name,
            frame: frame,
            supportsBrightness: brightness,
            supportsVolume: volume,
            isMain: main,
            isOnline: online
        )
    }

    private var left: CGRect { CGRect(x: 0, y: 0, width: 100, height: 100) }
    private var right: CGRect { CGRect(x: 200, y: 0, width: 100, height: 100) }

    private func resolve(
        _ target: KeyboardControlTarget,
        _ candidates: [ScreenCandidate],
        mouse: CGPoint = CGPoint(x: 50, y: 50),
        focused: CGDirectDisplayID? = nil,
        audio: String? = nil,
        volume: Bool = false
    ) -> [CGDirectDisplayID] {
        KeyboardControlResolver.resolve(
            target: target,
            candidates: candidates,
            mouseLocation: mouse,
            focusedDisplayID: focused,
            audioDeviceName: audio,
            requiresVolume: volume
        )
    }

    // MARK: - Target enum

    func testDefaultIsMouseScreen() {
        XCTAssertEqual(KeyboardControlTarget.default, .mouseScreen)
    }

    func testAllCasesAndRawValues() {
        XCTAssertEqual(
            KeyboardControlTarget.allCases,
            [.mouseScreen, .focusedScreen, .allSuitableScreens, .audioDeviceMatch]
        )
        XCTAssertEqual(KeyboardControlTarget.mouseScreen.rawValue, "mouseScreen")
        XCTAssertEqual(KeyboardControlTarget.focusedScreen.rawValue, "focusedScreen")
        XCTAssertEqual(KeyboardControlTarget.allSuitableScreens.rawValue, "allSuitableScreens")
        XCTAssertEqual(KeyboardControlTarget.audioDeviceMatch.rawValue, "audioDeviceMatch")
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(KeyboardControlTarget.audioDeviceMatch)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardControlTarget.self, from: data), .audioDeviceMatch)
    }

    // MARK: - mouseScreen

    func testMouseScreenPicksTheScreenUnderThePointer() {
        let a = candidate(id: 1, frame: left)
        let b = candidate(id: 2, frame: right)
        XCTAssertEqual(resolve(.mouseScreen, [a, b], mouse: CGPoint(x: 250, y: 50)), [2])
    }

    func testMouseScreenFallsBackToNearestCentre() {
        let a = candidate(id: 1, frame: left)
        let b = candidate(id: 2, frame: right)
        // x=140 is outside both frames; centres are 50 and 250 → nearest is a.
        XCTAssertEqual(resolve(.mouseScreen, [a, b], mouse: CGPoint(x: 140, y: 50)), [1])
    }

    func testMouseScreenFallsBackToMainWhenNothingEligible() {
        let a = candidate(id: 7, frame: left, brightness: false, volume: false, main: true)
        XCTAssertEqual(resolve(.mouseScreen, [a]), [7])
    }

    func testMouseScreenSkipsOfflineScreens() {
        let offline = candidate(id: 2, frame: left, online: false)
        let online = candidate(id: 9, frame: right)
        XCTAssertEqual(resolve(.mouseScreen, [offline, online], mouse: CGPoint(x: 50, y: 50)), [9])
    }

    func testMouseScreenSkipsCapabilityMismatch() {
        let noVolume = candidate(id: 2, frame: left, volume: false)
        let withVolume = candidate(id: 9, frame: right, volume: true)
        // Volume requested but the pointer is over the volume-less screen.
        XCTAssertEqual(resolve(.mouseScreen, [noVolume, withVolume], mouse: CGPoint(x: 50, y: 50), volume: true), [9])
    }

    func testMouseScreenOverlapIsDeterministicLowestID() {
        let a = candidate(id: 3, frame: left)
        let b = candidate(id: 1, frame: left)
        XCTAssertEqual(resolve(.mouseScreen, [a, b], mouse: CGPoint(x: 50, y: 50)), [1])
    }

    func testMouseScreenOverlapPrefersMain() {
        let a = candidate(id: 3, frame: left, main: true)
        let b = candidate(id: 1, frame: left)
        XCTAssertEqual(resolve(.mouseScreen, [a, b], mouse: CGPoint(x: 50, y: 50)), [3])
    }

    // MARK: - focusedScreen

    func testFocusedScreenUsesEligibleFocusedDisplay() {
        let a = candidate(id: 1, frame: left)
        let b = candidate(id: 2, frame: right)
        XCTAssertEqual(resolve(.focusedScreen, [a, b], focused: 2), [2])
    }

    func testFocusedScreenFallsBackWhenFocusedNotEligible() {
        let a = candidate(id: 1, frame: left)
        let b = candidate(id: 2, frame: right, volume: false)
        // Focused display 2 cannot do volume → fall back to the mouse chain.
        XCTAssertEqual(
            resolve(.focusedScreen, [a, b], mouse: CGPoint(x: 250, y: 50), focused: 2, volume: true),
            [1]
        )
    }

    func testFocusedScreenNilFallsBackToMouse() {
        let a = candidate(id: 1, frame: left)
        XCTAssertEqual(resolve(.focusedScreen, [a], focused: nil), [1])
    }

    func testFocusedScreenUnknownIDFallsBackToMouse() {
        let a = candidate(id: 1, frame: left)
        let b = candidate(id: 2, frame: right)
        XCTAssertEqual(resolve(.focusedScreen, [a, b], mouse: CGPoint(x: 250, y: 50), focused: 99), [2])
    }

    // MARK: - allSuitableScreens

    func testAllSuitableScreensReturnsEveryEligibleMainFirstThenAscendingID() {
        let a = candidate(id: 5, frame: left, main: true)
        let b = candidate(id: 2, frame: right)
        let c = candidate(id: 9, frame: CGRect(x: 400, y: 0, width: 100, height: 100))
        XCTAssertEqual(resolve(.allSuitableScreens, [c, b, a]), [5, 2, 9])
    }

    func testAllSuitableScreensSkipsOffline() {
        let a = candidate(id: 1, frame: left)
        let b = candidate(id: 2, frame: right, online: false)
        XCTAssertEqual(resolve(.allSuitableScreens, [a, b]), [1])
    }

    func testAllSuitableScreensSkipsCapabilityMismatch() {
        let a = candidate(id: 1, frame: left, volume: true)
        let b = candidate(id: 2, frame: right, volume: false)
        XCTAssertEqual(resolve(.allSuitableScreens, [a, b], volume: true), [1])
    }

    func testAllSuitableScreensFallsBackToMainWhenNoneEligible() {
        let a = candidate(id: 4, frame: left, volume: false, main: true)
        let b = candidate(id: 2, frame: right, volume: false)
        XCTAssertEqual(resolve(.allSuitableScreens, [a, b], volume: true), [4])
    }

    // MARK: - audioDeviceMatch

    func testAudioDeviceMatchExact() {
        let a = candidate(id: 1, name: "LG UltraFine")
        let b = candidate(id: 2, name: "Studio Display")
        XCTAssertEqual(resolve(.audioDeviceMatch, [a, b], audio: "LG UltraFine"), [1])
    }

    func testAudioDeviceMatchIsCaseInsensitive() {
        let a = candidate(id: 1, name: "LG UltraFine")
        XCTAssertEqual(resolve(.audioDeviceMatch, [a], audio: "lg ultrafine"), [1])
    }

    func testAudioDeviceMatchPartialDisplayContainsDevice() {
        let a = candidate(id: 1, name: "LG UltraFine")
        XCTAssertEqual(resolve(.audioDeviceMatch, [a], audio: "LG"), [1])
    }

    func testAudioDeviceMatchPartialDeviceContainsDisplay() {
        let a = candidate(id: 1, name: "DELL U2720Q")
        XCTAssertEqual(resolve(.audioDeviceMatch, [a], audio: "DELL U2720Q Monitor"), [1])
    }

    func testAudioDeviceMatchPrefersExactOverPartial() {
        let partial = candidate(id: 1, name: "LG UltraFine 5K")
        let exact = candidate(id: 2, name: "LG")
        XCTAssertEqual(resolve(.audioDeviceMatch, [partial, exact], audio: "LG"), [2])
    }

    func testAudioDeviceMatchNoMatchFallsBackToMouse() {
        let a = candidate(id: 1, name: "Alpha", frame: left)
        let b = candidate(id: 2, name: "Beta", frame: right)
        XCTAssertEqual(resolve(.audioDeviceMatch, [a, b], mouse: CGPoint(x: 250, y: 50), audio: "Nonexistent"), [2])
    }

    func testAudioDeviceMatchNilNameFallsBackToMouse() {
        let a = candidate(id: 1, name: "Alpha", frame: left)
        XCTAssertEqual(resolve(.audioDeviceMatch, [a], audio: nil), [1])
    }

    func testAudioDeviceMatchSkipsIneligibleMatch() {
        let ineligible = candidate(id: 1, name: "LG", frame: left, volume: false)
        let eligible = candidate(id: 2, name: "Other", frame: right, volume: true)
        XCTAssertEqual(resolve(.audioDeviceMatch, [ineligible, eligible], audio: "LG", volume: true), [2])
    }

    // MARK: - matches

    func testMatchesExactPartialAndCaseInsensitive() {
        XCTAssertTrue(KeyboardControlResolver.matches(audioDeviceName: "LG TV", displayName: "LG TV"))
        XCTAssertTrue(KeyboardControlResolver.matches(audioDeviceName: "lg", displayName: "LG TV"))
        XCTAssertTrue(KeyboardControlResolver.matches(audioDeviceName: "LG TV", displayName: "lg"))
        XCTAssertFalse(KeyboardControlResolver.matches(audioDeviceName: "Sony", displayName: "Samsung"))
    }

    func testMatchesEmptyStringsAreFalse() {
        XCTAssertFalse(KeyboardControlResolver.matches(audioDeviceName: "", displayName: "LG"))
        XCTAssertFalse(KeyboardControlResolver.matches(audioDeviceName: "LG", displayName: ""))
    }

    // MARK: - Totality

    func testAllOfflineReturnsEmpty() {
        let a = candidate(id: 1, frame: left, online: false)
        XCTAssertEqual(resolve(.mouseScreen, [a]), [])
        XCTAssertEqual(resolve(.allSuitableScreens, [a]), [])
        XCTAssertEqual(resolve(.audioDeviceMatch, [a], audio: "LG"), [])
    }

    func testNeverEmptyWhenSomethingIsOnline() {
        let a = candidate(id: 1, frame: left, brightness: false, volume: false, main: true)
        for target in KeyboardControlTarget.allCases {
            XCTAssertFalse(resolve(target, [a], volume: true).isEmpty, "\(target) must still return the main display")
        }
    }

    func testDeterministicAcrossRepeatedCalls() {
        let candidates = [
            candidate(id: 3, frame: left),
            candidate(id: 1, frame: right, main: true),
            candidate(id: 2, frame: CGRect(x: 400, y: 0, width: 100, height: 100))
        ]
        let first = resolve(.allSuitableScreens, candidates)
        for _ in 0..<20 {
            XCTAssertEqual(resolve(.allSuitableScreens, candidates), first)
        }
    }

    func testNearestTieBreakIsLowestID() {
        // Two screens equidistant from the pointer, neither containing it.
        let a = candidate(id: 8, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let b = candidate(id: 2, frame: CGRect(x: 100, y: 0, width: 100, height: 100))
        XCTAssertEqual(resolve(.mouseScreen, [a, b], mouse: CGPoint(x: 100, y: 200)), [2])
    }
}
