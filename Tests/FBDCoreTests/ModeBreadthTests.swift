import XCTest
@testable import FBDCore

/// Mode-list breadth: the pure `filter(_:options:nativeAspect:)` over
/// `[DisplayMode]`, the refresh-rate dedupe/sort, and the rate formatting/matching
/// helpers. Deterministic — no display, no WindowServer, no defaults.
final class ModeBreadthTests: XCTestCase {

    private func makeMode(
        number: Int32 = 1,
        width: Int32,
        height: Int32,
        pixelsWide: Int32? = nil,
        pixelsHigh: Int32? = nil,
        refreshRate: Double = 60,
        hiDPI: Bool = false,
        safe: Bool = true
    ) -> DisplayMode {
        var flags: Int32 = 0
        if safe { flags |= DisplayMode.safeFlag }
        if hiDPI { flags |= DisplayMode.hiDPIFlag }
        return DisplayMode(
            modeNumber: number,
            flags: flags,
            width: width,
            height: height,
            pixelsWide: pixelsWide ?? (hiDPI ? width * 2 : width),
            pixelsHigh: pixelsHigh ?? (hiDPI ? height * 2 : height),
            refreshRate: refreshRate,
            encoding: "RGB "
        )
    }

    private func ids(_ modes: [DisplayMode]) -> [Int32] { modes.map { $0.modeNumber } }

    // MARK: - Safe / unsafe / invalid

    func testStandardKeepsAPlainSafeMode() {
        let mode = makeMode(number: 1, width: 1920, height: 1080)
        XCTAssertEqual(ids(ModeFavourites.filter([mode], options: .standard, nativeAspect: nil)), [1])
    }

    func testStandardDropsUnsafeModes() {
        let mode = makeMode(number: 1, width: 1920, height: 1080, safe: false)
        XCTAssertTrue(ModeFavourites.filter([mode], options: .standard, nativeAspect: nil).isEmpty)
    }

    func testShowUnsafeOrInvalidKeepsUnsafeModes() {
        let mode = makeMode(number: 1, width: 1920, height: 1080, safe: false)
        var options = ModeFilterOptions.standard
        options.showUnsafeOrInvalid = true
        XCTAssertEqual(ids(ModeFavourites.filter([mode], options: options, nativeAspect: nil)), [1])
    }

    func testDegenerateModeIsDroppedByDefault() {
        let mode = makeMode(number: 1, width: 0, height: 1080)
        XCTAssertTrue(ModeFavourites.filter([mode], options: .standard, nativeAspect: nil).isEmpty)
    }

    // MARK: - Below 720p / above 8K

    func testStandardDropsBelow720p() {
        let mode = makeMode(number: 1, width: 640, height: 480)
        XCTAssertTrue(ModeFavourites.filter([mode], options: .standard, nativeAspect: nil).isEmpty)
    }

    func testExactly720pSurvives() {
        let mode = makeMode(number: 1, width: 1280, height: 720)
        XCTAssertEqual(ids(ModeFavourites.filter([mode], options: .standard, nativeAspect: nil)), [1])
    }

    func testIncludeBelow720pKeepsSmallModes() {
        let mode = makeMode(number: 1, width: 640, height: 480)
        var options = ModeFilterOptions.standard
        options.includeBelow720p = true
        XCTAssertEqual(ids(ModeFavourites.filter([mode], options: options, nativeAspect: nil)), [1])
    }

    func testStandardDropsAbove8K() {
        let mode = makeMode(number: 1, width: 10240, height: 4320)
        XCTAssertTrue(ModeFavourites.filter([mode], options: .standard, nativeAspect: nil).isEmpty)
    }

    func testIncludeAbove8KKeepsLargeModes() {
        let mode = makeMode(number: 1, width: 10240, height: 4320)
        var options = ModeFilterOptions.standard
        options.includeAbove8K = true
        XCTAssertEqual(ids(ModeFavourites.filter([mode], options: options, nativeAspect: nil)), [1])
    }

    // MARK: - HiDPI override

    func testAlwaysShowHiDPIRescuesASub720Mode() {
        let mode = makeMode(number: 1, width: 640, height: 480, hiDPI: true)
        XCTAssertEqual(ids(ModeFavourites.filter([mode], options: .standard, nativeAspect: nil)), [1])
    }

    func testDisablingAlwaysShowHiDPIDropsASub720HiDPIMode() {
        let mode = makeMode(number: 1, width: 640, height: 480, hiDPI: true)
        var options = ModeFilterOptions.standard
        options.alwaysShowHiDPI = false
        XCTAssertTrue(ModeFavourites.filter([mode], options: options, nativeAspect: nil).isEmpty)
    }

    func testAlwaysShowHiDPIRescuesAnUnsafeHiDPIMode() {
        let mode = makeMode(number: 1, width: 1920, height: 1080, hiDPI: true, safe: false)
        XCTAssertEqual(ids(ModeFavourites.filter([mode], options: .standard, nativeAspect: nil)), [1])
    }

    func testDisablingAlwaysShowHiDPIDropsAnUnsafeHiDPIMode() {
        let mode = makeMode(number: 1, width: 1920, height: 1080, hiDPI: true, safe: false)
        var options = ModeFilterOptions.standard
        options.alwaysShowHiDPI = false
        XCTAssertTrue(ModeFavourites.filter([mode], options: options, nativeAspect: nil).isEmpty)
    }

    // MARK: - Mixed modes

    func testStandardDropsMixedHiDPIModes() {
        // HiDPI but pixelsWide is 2560, not 2×1920 — a fractional "more space"
        // scale.
        let mode = makeMode(
            number: 1, width: 1920, height: 1080,
            pixelsWide: 2560, pixelsHigh: 1440, hiDPI: true
        )
        XCTAssertTrue(ModeFavourites.filter([mode], options: .standard, nativeAspect: nil).isEmpty)
    }

    func testShowMixedModesKeepsMixedModes() {
        let mode = makeMode(
            number: 1, width: 1920, height: 1080,
            pixelsWide: 2560, pixelsHigh: 1440, hiDPI: true
        )
        var options = ModeFilterOptions.standard
        options.showMixedModes = true
        XCTAssertEqual(ids(ModeFavourites.filter([mode], options: options, nativeAspect: nil)), [1])
    }

    func testAlwaysShowHiDPIDoesNotOverrideTheMixedRule() {
        let mode = makeMode(
            number: 1, width: 1920, height: 1080,
            pixelsWide: 2560, pixelsHigh: 1440, hiDPI: true
        )
        // alwaysShowHiDPI is on by default; the mixed rule is about shape, so
        // the mode is still hidden.
        XCTAssertTrue(ModeFavourites.filter([mode], options: .standard, nativeAspect: nil).isEmpty)
    }

    func testIsMixedDetectsFractionalHiDPIOnly() {
        XCTAssertFalse(ModeFavourites.isMixed(makeMode(width: 1920, height: 1080, hiDPI: true)))
        XCTAssertFalse(ModeFavourites.isMixed(makeMode(width: 1920, height: 1080)))
        XCTAssertTrue(ModeFavourites.isMixed(
            makeMode(width: 1920, height: 1080, pixelsWide: 2560, pixelsHigh: 1440, hiDPI: true)
        ))
    }

    // MARK: - Native aspect

    func testOnlyNativeAspectKeepsMatchingModes() {
        let widescreen = makeMode(number: 1, width: 1920, height: 1080)
        let ultrawide = makeMode(number: 2, width: 2560, height: 1080)
        var options = ModeFilterOptions.standard
        options.onlyNativeAspect = true
        let result = ModeFavourites.filter([widescreen, ultrawide], options: options, nativeAspect: 16.0 / 9.0)
        XCTAssertEqual(ids(result), [1])
    }

    func testOnlyNativeAspectWithNilAspectKeepsEveryAspect() {
        let ultrawide = makeMode(number: 2, width: 2560, height: 1080)
        var options = ModeFilterOptions.standard
        options.onlyNativeAspect = true
        XCTAssertEqual(ids(ModeFavourites.filter([ultrawide], options: options, nativeAspect: nil)), [2])
    }

    // MARK: - Totality / order

    func testFilterPreservesInputOrder() {
        let a = makeMode(number: 3, width: 1920, height: 1080)
        let b = makeMode(number: 1, width: 1280, height: 720)
        let c = makeMode(number: 2, width: 2560, height: 1440)
        XCTAssertEqual(ids(ModeFavourites.filter([a, b, c], options: .standard, nativeAspect: nil)), [3, 1, 2])
    }

    func testFilterIsTotalOnEmptyInput() {
        XCTAssertTrue(ModeFavourites.filter([], options: .standard, nativeAspect: nil).isEmpty)
    }

    func testStandardOptionsAreTheConservativeDefaults() {
        XCTAssertFalse(ModeFilterOptions.standard.showMixedModes)
        XCTAssertFalse(ModeFilterOptions.standard.showUnsafeOrInvalid)
        XCTAssertFalse(ModeFilterOptions.standard.includeBelow720p)
        XCTAssertFalse(ModeFilterOptions.standard.includeAbove8K)
        XCTAssertTrue(ModeFilterOptions.standard.alwaysShowHiDPI)
        XCTAssertFalse(ModeFilterOptions.standard.onlyNativeAspect)
    }

    // MARK: - Refresh rate list

    func testRefreshRatesDedupeWithinTolerance() {
        let modes = [
            makeMode(number: 1, width: 1920, height: 1080, refreshRate: 60.0),
            makeMode(number: 2, width: 1280, height: 720, refreshRate: 60.005),
            makeMode(number: 3, width: 2560, height: 1440, refreshRate: 120.0)
        ]
        XCTAssertEqual(ModeFavourites.refreshRates(from: modes), [120.0, 60.0])
    }

    func testRefreshRatesAreSortedDescending() {
        let modes = [
            makeMode(number: 1, width: 1920, height: 1080, refreshRate: 30),
            makeMode(number: 2, width: 1920, height: 1080, refreshRate: 144),
            makeMode(number: 3, width: 1920, height: 1080, refreshRate: 60)
        ]
        XCTAssertEqual(ModeFavourites.refreshRates(from: modes), [144, 60, 30])
    }

    func testRefreshRatesDropsZeroAndInvalidRates() {
        let modes = [
            makeMode(number: 1, width: 1920, height: 1080, refreshRate: 0),
            makeMode(number: 2, width: 1920, height: 1080, refreshRate: -60),
            makeMode(number: 3, width: 1920, height: 1080, refreshRate: Double.nan),
            makeMode(number: 4, width: 1920, height: 1080, refreshRate: Double.infinity),
            makeMode(number: 5, width: 1920, height: 1080, refreshRate: 60)
        ]
        XCTAssertEqual(ModeFavourites.refreshRates(from: modes), [60])
    }

    func testRefreshRatesIsEmptyForNoValidRates() {
        XCTAssertTrue(ModeFavourites.refreshRates(from: []).isEmpty)
    }

    // MARK: - Refresh rate label + matching

    func testRefreshRateLabelFormatsAWholeNumber() {
        XCTAssertEqual(ModeFavourites.refreshRateLabel(60), "60 Hz")
    }

    func testRefreshRateLabelFormatsAFractionalRate() {
        XCTAssertEqual(ModeFavourites.refreshRateLabel(59.94), "59.94 Hz")
    }

    func testRefreshRateLabelIsEmptyForZeroAndNonFinite() {
        XCTAssertEqual(ModeFavourites.refreshRateLabel(0), "")
        XCTAssertEqual(ModeFavourites.refreshRateLabel(Double.nan), "")
    }

    func testModeMatchingRefreshRateFindsWithinTolerance() {
        let sixty = makeMode(number: 1, width: 1920, height: 1080, refreshRate: 60)
        let ninetyFour = makeMode(number: 2, width: 1920, height: 1080, refreshRate: 59.94)
        XCTAssertEqual(ModeFavourites.mode(in: [sixty, ninetyFour], matchingRefreshRate: 59.94)?.modeNumber, 2)
        XCTAssertEqual(ModeFavourites.mode(in: [sixty, ninetyFour], matchingRefreshRate: 60)?.modeNumber, 1)
    }

    func testModeMatchingRefreshRateIsNilWhenNoneIsCloseEnough() {
        let sixty = makeMode(number: 1, width: 1920, height: 1080, refreshRate: 60)
        XCTAssertNil(ModeFavourites.mode(in: [sixty], matchingRefreshRate: 120))
    }
}
