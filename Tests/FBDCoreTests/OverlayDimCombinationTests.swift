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
}
