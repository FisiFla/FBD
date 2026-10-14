import XCTest
@testable import FBDCore

/// The curated inline mode list: what is worth showing at a glance, and what stays behind
/// "show all". Pure, so the rules are asserted without a display.
final class CuratedModesTests: XCTestCase {
    private func mode(
        _ number: Int32,
        _ width: Int32,
        _ height: Int32,
        hiDPI: Bool = false
    ) -> DisplayMode {
        var flags: Int32 = DisplayMode.safeFlag
        if hiDPI { flags |= DisplayMode.hiDPIFlag }
        return DisplayMode(
            modeNumber: number,
            flags: flags,
            width: width,
            height: height,
            pixelsWide: hiDPI ? width * 2 : width,
            pixelsHigh: hiDPI ? height * 2 : height,
            refreshRate: 60,
            encoding: "RGB "
        )
    }

    func testOneRowPerLogicalSize() {
        let sdr = mode(1, 1920, 1080)
        let hiDPI = mode(2, 1920, 1080, hiDPI: true)
        let smaller = mode(3, 1280, 720)

        let curated = CuratedModes.curated(from: [sdr, hiDPI, smaller], current: sdr)

        XCTAssertEqual(curated.count, 2, "one row per size, not one per mode")
        XCTAssertEqual(curated.map(\.modeNumber), [1, 3], "largest first")
    }

    /// The row for the size on screen has to be the mode on screen — otherwise the list shows
    /// no checkmark at all and the picker disagrees with the display.
    func testTheModeInEffectOwnsItsOwnSize() {
        let sdr = mode(1, 1920, 1080)
        let hiDPI = mode(2, 1920, 1080, hiDPI: true)

        let curated = CuratedModes.curated(from: [sdr, hiDPI], current: sdr)

        XCTAssertEqual(curated.map(\.modeNumber), [1])
    }

    /// Where the current mode is *not*, the variant wins — that is the preference the whole
    /// list exists to express.
    func testAVariantIsPreferredAtASizeTheCurrentModeDoesNotOccupy() {
        let current = mode(1, 1920, 1080)
        let sdr = mode(2, 1280, 720)
        let hiDPI = mode(3, 1280, 720, hiDPI: true)

        let curated = CuratedModes.curated(from: [current, sdr, hiDPI], current: current)

        XCTAssertEqual(curated.map(\.modeNumber), [1, 3])
    }

    /// A different shape is not one of this display's scaled steps, so it belongs to the full
    /// list rather than the glance.
    func testADifferentAspectIsLeftToTheFullList() {
        let standard = mode(1, 1920, 1080)
        let ultrawide = mode(2, 2560, 1080)

        let curated = CuratedModes.curated(from: [standard, ultrawide], current: standard)

        XCTAssertEqual(curated.map(\.modeNumber), [1])
    }

    /// Truncation must never drop the mode that is on screen. All these modes share an aspect
    /// ratio of exactly 1.6, so they are one family and there are more than `limit` of them.
    func testTheModeInEffectSurvivesTruncation() {
        var modes: [DisplayMode] = []
        for index in 0..<14 {
            let width = Int32(1600 - 40 * index)
            let height = Int32(1000 - 25 * index)
            modes.append(mode(Int32(index + 1), width, height))
        }
        let smallest = modes[13]

        let curated = CuratedModes.curated(from: modes, current: smallest)

        XCTAssertEqual(curated.count, CuratedModes.limit)
        XCTAssertTrue(
            curated.contains { $0.modeNumber == smallest.modeNumber },
            "the smallest size sorts last and would be cut without the guard"
        )
    }

    func testNoCurrentModeStillCuratesToTheLimit() {
        var modes: [DisplayMode] = []
        for number in 1...14 { modes.append(mode(Int32(number), 1920, 1080)) }
        XCTAssertEqual(CuratedModes.curated(from: modes, current: nil).count, CuratedModes.limit)
    }

    func testAnEmptyListStaysEmpty() {
        XCTAssertTrue(CuratedModes.curated(from: [], current: nil).isEmpty)
    }

    /// The "show all" affordance must not be offered when curation hides nothing.
    func testHidesAnythingIsFalseWhenNothingWasHidden() {
        let modes = [mode(1, 1920, 1080), mode(2, 1280, 720)]
        XCTAssertFalse(CuratedModes.hidesAnything(from: modes, current: modes[0]))

        let withVariant = modes + [mode(3, 1920, 1080, hiDPI: true)]
        XCTAssertTrue(CuratedModes.hidesAnything(from: withVariant, current: modes[0]))
    }
}
