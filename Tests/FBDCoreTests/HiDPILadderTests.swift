import XCTest
import FBDCore

/// The HiDPI ladder generator (issue #27).
///
/// The ladder is pure arithmetic: the native resolution stepped down in
/// sixteen-point increments, the aspect held, the floor respected. Every
/// property the issue asks for is checked here, without a display.
final class HiDPILadderTests: XCTestCase {
    /// A 4K panel: 3840×2160.
    private let nativeWidth = 3840
    private let nativeHeight = 2160

    func testLadderStartsAtTheNativeSize() {
        let modes = HiDPILadder.logicalSizes(
            nativeWidth: nativeWidth, nativeHeight: nativeHeight, minimumScale: 0.5
        )

        XCTAssertEqual(modes.first?.logicalWidth, nativeWidth)
        XCTAssertEqual(modes.first?.logicalHeight, nativeHeight)
    }

    func testStepsAreSixteenPointsWide() {
        let modes = HiDPILadder.logicalSizes(
            nativeWidth: nativeWidth, nativeHeight: nativeHeight, minimumScale: 0.5
        )

        XCTAssertGreaterThan(modes.count, 2)
        for (previous, next) in zip(modes, modes.dropFirst()) {
            XCTAssertEqual(previous.logicalWidth - next.logicalWidth, 16,
                           "the ladder must step by sixteen points")
        }
    }

    func testAspectIsHeld() {
        let modes = HiDPILadder.logicalSizes(
            nativeWidth: nativeWidth, nativeHeight: nativeHeight, minimumScale: 0.5
        )

        for mode in modes {
            let expected = Double(mode.logicalWidth) * Double(nativeHeight) / Double(nativeWidth)
            XCTAssertEqual(Double(mode.logicalHeight), expected.rounded(), accuracy: 1,
                           "the height must follow the native aspect at \(mode.logicalWidth)")
        }
    }

    func testFloorIsRespected() {
        let modes = HiDPILadder.logicalSizes(
            nativeWidth: nativeWidth, nativeHeight: nativeHeight, minimumScale: 0.5
        )

        let smallest = modes.last?.logicalWidth ?? 0
        XCTAssertGreaterThanOrEqual(smallest, Int((Double(nativeWidth) * 0.5).rounded(.up)))
        XCTAssertEqual(smallest % 16, 0, "the ladder stays on the sixteen-point grid")
    }

    func testMinimumSizeIsKept() {
        let modes = HiDPILadder.logicalSizes(
            nativeWidth: nativeWidth, nativeHeight: nativeHeight, minimumScale: 0.5
        )

        for mode in modes {
            XCTAssertGreaterThanOrEqual(mode.logicalWidth, HiDPILadder.minimumLogicalWidth)
            XCTAssertGreaterThanOrEqual(mode.logicalHeight, HiDPILadder.minimumLogicalHeight)
        }
    }

    func testLadderIsMonotonic() {
        let modes = HiDPILadder.logicalSizes(
            nativeWidth: nativeWidth, nativeHeight: nativeHeight, minimumScale: 0.5
        )

        for (previous, next) in zip(modes, modes.dropFirst()) {
            XCTAssertLessThan(next.logicalWidth, previous.logicalWidth)
            XCTAssertLessThanOrEqual(next.logicalHeight, previous.logicalHeight)
        }
    }

    func testBackingIsTwiceTheLogicalSize() {
        let mode = HiDPIScaledMode(logicalWidth: 1920, logicalHeight: 1080)

        XCTAssertEqual(mode.backingWidth, 3840)
        XCTAssertEqual(mode.backingHeight, 2160)
    }

    func testEncodingIsEightBytesBigEndian() {
        let mode = HiDPIScaledMode(logicalWidth: 1920, logicalHeight: 1080)

        let encoded = HiDPILadder.encode(mode)

        XCTAssertEqual(encoded.count, 8)
        XCTAssertEqual(Array(encoded.prefix(4)), [0x00, 0x00, 0x0F, 0x00])   // 3840
        XCTAssertEqual(Array(encoded.suffix(4)), [0x00, 0x00, 0x08, 0x70])   // 2160
    }

    func testScaleResolutionsHasOneEntryPerMode() {
        let modes = HiDPILadder.logicalSizes(
            nativeWidth: nativeWidth, nativeHeight: nativeHeight, minimumScale: 0.5
        )

        let entries = HiDPILadder.scaleResolutions(modes)

        XCTAssertEqual(entries.count, modes.count)
        XCTAssertTrue(entries.allSatisfy { $0.count == 8 })
    }

    func testUnknownNativeSizeGivesNoModes() {
        let modes = HiDPILadder.logicalSizes(nativeWidth: 0, nativeHeight: 0, minimumScale: 0.5)

        XCTAssertTrue(modes.isEmpty)
    }

    func testAPanelSmallerThanTheMinimumGivesNoModes() {
        let modes = HiDPILadder.logicalSizes(nativeWidth: 640, nativeHeight: 480, minimumScale: 0.5)

        XCTAssertTrue(modes.isEmpty)
    }
}
