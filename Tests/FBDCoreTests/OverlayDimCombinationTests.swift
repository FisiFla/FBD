import XCTest
@testable import FBDCore

/// The two dim sources — the brightness route and the dim-to-black/lock path — write the same
/// overlay window, so how they combine is the whole of the interesting behaviour here. The
/// window itself cannot be unit-tested; this can.
@MainActor
final class OverlayDimCombinationTests: XCTestCase {
    func testNoSourceIsNoDim() {
        XCTAssertEqual(OverlayController.combinedOpacity(control: nil, brightness: nil), 0)
        XCTAssertEqual(OverlayController.combinedOpacity(control: 0, brightness: 0), 0)
    }

    /// The darkest source wins, whichever side of the pair asks for it.
    func testTheDarkestSourceWins() {
        XCTAssertEqual(OverlayController.combinedOpacity(control: 0.25, brightness: 0.75), 0.75)
        XCTAssertEqual(OverlayController.combinedOpacity(control: 0.9, brightness: 0.4), 0.9)
    }

    /// Releasing one source leaves the other in force — the reason they are tracked apart
    /// rather than as a single value.
    func testReleasingOneSourceLeavesTheOtherInForce() {
        XCTAssertEqual(OverlayController.combinedOpacity(control: nil, brightness: 0.5), 0.5)
        XCTAssertEqual(OverlayController.combinedOpacity(control: 0.5, brightness: 0), 0.5)
    }

    func testOutOfRangeInputsAreClampedRatherThanEscaping() {
        XCTAssertEqual(OverlayController.combinedOpacity(control: 4, brightness: nil), 1)
        XCTAssertEqual(OverlayController.combinedOpacity(control: -3, brightness: -1), 0)
    }

    /// A display starts undimmed: nothing writes `softwareDim` until a route asks for one, so
    /// the default has to be "no dim" rather than "unknown".
    func testADisplayStartsUndimmedAndClampsWhatItIsTold() {
        let display = Display(
            id: 5,
            name: "Test",
            isBuiltin: false,
            vendorNumber: 1,
            modelNumber: 2,
            serialNumber: 3,
            bounds: .zero,
            isOnline: true,
            isActive: true
        )
        XCTAssertEqual(display.softwareDim, 1)

        display.updateSoftwareDim(0.25)
        XCTAssertEqual(display.softwareDim, 0.25, accuracy: 1e-12)

        display.updateSoftwareDim(3)
        XCTAssertEqual(display.softwareDim, 1, accuracy: 1e-12)

        display.updateSoftwareDim(-1)
        XCTAssertEqual(display.softwareDim, 0, accuracy: 1e-12)
    }

    // MARK: - The filter sources

    /// The capture pipeline needs Screen Recording and a real display, neither
    /// of which a unit test has, so these cases drive the state that decides
    /// what the pipeline would run. A display id that has no bounds keeps the
    /// pipeline out of the way (the overlay checks the geometry first).
    private static let fakeDisplayID: CGDirectDisplayID = 99

    /// A filter that was turned off must leave nothing behind: the stored
    /// parameters are what the next boost or blend composition picks up, and
    /// the amber cast came back with the next brightness write.
    func testTurningTheFilterOffLeavesNoStoredParams() {
        let overlay = OverlayController()
        let id = Self.fakeDisplayID
        // The user's own filter: an amber cast.
        overlay.setScreenFilter(ScreenFilterParams(temperature: 0), displayID: id)
        XCTAssertEqual(overlay.composedFilterParams(for: id).temperature, 0, accuracy: 1e-9)

        overlay.stopScreenFilter(displayID: id)

        XCTAssertEqual(overlay.composedFilterParams(for: id).temperature, 1, accuracy: 1e-9,
                       "a turned-off filter leaves no stored params")
    }

    /// The blend is what brought the amber cast back before: a later
    /// composition must not carry a filter that was turned off.
    func testALaterBlendCompositionDoesNotCarryTheTurnedOffFilter() {
        let overlay = OverlayController()
        let id = Self.fakeDisplayID
        overlay.setScreenFilter(ScreenFilterParams(temperature: 0), displayID: id)
        overlay.stopScreenFilter(displayID: id)

        // A later blend composition.
        overlay.setBrightnessBlendFactor(0.5, displayID: id)
        let composed = overlay.composedFilterParams(for: id)

        XCTAssertEqual(composed.temperature, 1, accuracy: 1e-9,
                       "the amber cast must not come back with the blend")
        XCTAssertEqual(composed.brightness, 0.5, accuracy: 1e-9,
                       "and the blend factor is what is left")
    }

    /// "Off" is one state, not two: a neutral filter stores nothing, so it
    /// cannot be resurrected by a later composition either.
    func testANeutralFilterStoresNothing() {
        let overlay = OverlayController()
        let id = Self.fakeDisplayID
        overlay.setScreenFilter(ScreenFilterParams(temperature: 0), displayID: id)
        overlay.setScreenFilter(.neutral, displayID: id)

        XCTAssertEqual(overlay.composedFilterParams(for: id).temperature, 1, accuracy: 1e-9)
    }

    /// The three sources compose: the user's own filter, the software boost
    /// and the below-floor blend all touch the same brightness multiplier, so
    /// they multiply rather than replace each other.
    func testTheThreeSourcesCompose() {
        let overlay = OverlayController()
        let id = Self.fakeDisplayID
        overlay.setScreenFilter(ScreenFilterParams(brightness: 0.5), displayID: id)
        overlay.setSoftwareBoost(2, displayID: id)
        overlay.setBrightnessBlendFactor(0.5, displayID: id)

        XCTAssertEqual(overlay.composedFilterParams(for: id).brightness, 0.5 * 2 * 0.5, accuracy: 1e-9)
    }

    /// Releasing the blend (a factor of 1) drops it: a later composition must
    /// not dim the screen by a factor the brightness route has given up on.
    func testReleasingTheBlendDropsIt() {
        let overlay = OverlayController()
        let id = Self.fakeDisplayID
        overlay.setBrightnessBlendFactor(0.5, displayID: id)
        overlay.setBrightnessBlendFactor(1, displayID: id)

        XCTAssertEqual(overlay.composedFilterParams(for: id).brightness, 1, accuracy: 1e-9)
    }
}
