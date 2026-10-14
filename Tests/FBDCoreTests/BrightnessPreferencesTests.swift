import XCTest
import FBDCore

/// Pure tests for the BetterDisplay-parity brightness model: the
/// `BrightnessPreferences` value type, its `clamped()` normaliser, the
/// `BrightnessCurve` mapping, the nits conversion helpers, and the
/// `Settings`-backed persistence. No display, no private API — every case is
/// a value-in / value-out check.
final class BrightnessPreferencesTests: XCTestCase {
    /// The literal key so a test can clear the blob; it is not public API.
    private let prefsKey = "brightnessPreferences.v1"

    override func setUp() {
        super.setUp()
        Settings.defaults.removeObject(forKey: prefsKey)
    }

    override func tearDown() {
        Settings.defaults.removeObject(forKey: prefsKey)
        super.tearDown()
    }

    // MARK: - Defaults & policy

    func testStandardDefaultsMatchSpec() {
        let p = BrightnessPreferences.standard
        XCTAssertTrue(p.preferHardwareControl)
        XCTAssertEqual(p.hardwareMinNits, 4)
        XCTAssertEqual(p.hardwareMaxNits, 500)
        XCTAssertEqual(p.hdrPeakSDRNits, 500)
        XCTAssertEqual(p.hdrPeakHDRNits, 1600)
        XCTAssertEqual(p.softwareZeroPercent, 0)
        XCTAssertEqual(p.minHardwarePercent, 0)
    }

    func testStandardUpscaleAndSwitchoverAreWithinRange() {
        let p = BrightnessPreferences.standard
        XCTAssertGreaterThanOrEqual(p.upscaleMaxPercent, 100)
        XCTAssertGreaterThanOrEqual(p.dimmingSwitchoverPercent, 0)
        XCTAssertLessThanOrEqual(p.dimmingSwitchoverPercent, 100)
    }

    func testStandardPolicyIsAssumeLastUsed() {
        XCTAssertEqual(BrightnessPreferences.standard.startupControlValuePolicy, .assumeLastUsed)
    }

    func testStandardIsAlreadyClamped() {
        XCTAssertEqual(BrightnessPreferences.standard.clamped(), BrightnessPreferences.standard)
    }

    func testPolicyHasExactlyThreeCases() {
        XCTAssertEqual(StartupControlValuePolicy.allCases.count, 3)
        XCTAssertEqual(
            Set(StartupControlValuePolicy.allCases),
            Set([.assumeLastUsed, .writeToDevice, .readFromDevice])
        )
    }

    func testPolicyRawValues() {
        XCTAssertEqual(StartupControlValuePolicy.assumeLastUsed.rawValue, "assumeLastUsed")
        XCTAssertEqual(StartupControlValuePolicy.writeToDevice.rawValue, "writeToDevice")
        XCTAssertEqual(StartupControlValuePolicy.readFromDevice.rawValue, "readFromDevice")
    }

    func testPolicyCodableRoundTrip() throws {
        for policy in StartupControlValuePolicy.allCases {
            let data = try JSONEncoder().encode(policy)
            XCTAssertEqual(try JSONDecoder().decode(StartupControlValuePolicy.self, from: data), policy)
        }
    }

    func testPreferencesCodableRoundTrip() throws {
        let p = BrightnessPreferences(
            preferHardwareControl: false,
            hardwareMinNits: 8,
            hardwareMaxNits: 620,
            hdrPeakSDRNits: 620,
            hdrPeakHDRNits: 1800,
            softwareZeroPercent: 12,
            minHardwarePercent: 5,
            dimmingSwitchoverPercent: 40,
            upscaleMaxPercent: 350,
            startupControlValuePolicy: .readFromDevice
        )
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(BrightnessPreferences.self, from: data), p)
    }

    // MARK: - Clamping / inversion repair

    func testClampSwapsInvertedHardwareNits() {
        let p = BrightnessPreferences(hardwareMinNits: 800, hardwareMaxNits: 200).clamped()
        XCTAssertEqual(p.hardwareMinNits, 200)
        XCTAssertEqual(p.hardwareMaxNits, 800)
        XCTAssertGreaterThanOrEqual(p.hardwareMaxNits - p.hardwareMinNits, 0)
    }

    func testClampNegativeNitsBecomeZero() {
        let p = BrightnessPreferences(hardwareMinNits: -50, hardwareMaxNits: 200).clamped()
        XCTAssertEqual(p.hardwareMinNits, 0)
        XCTAssertEqual(p.hardwareMaxNits, 200)
    }

    func testClampNaNNitsFallBackToDefaults() {
        let p = BrightnessPreferences(hardwareMinNits: .nan, hardwareMaxNits: .nan).clamped()
        XCTAssertEqual(p.hardwareMinNits, 4)
        XCTAssertEqual(p.hardwareMaxNits, 500)
    }

    /// An infinity is as much a sign of a corrupt blob as a NaN, so it takes the
    /// same path: fall back to the field's default. (Clamping it to the 40 000-nit
    /// ceiling instead would let a hand-edited blob raise the ceiling further than
    /// any sane panel, for no benefit.)
    func testClampInfiniteNitsFallBackToDefaults() {
        let p = BrightnessPreferences(hardwareMaxNits: .infinity).clamped()
        XCTAssertEqual(p.hardwareMaxNits, 500)
    }

    func testClampSwapsInvertedPeaks() {
        let p = BrightnessPreferences(hdrPeakSDRNits: 2000, hdrPeakHDRNits: 800).clamped()
        XCTAssertEqual(p.hdrPeakSDRNits, 800)
        XCTAssertEqual(p.hdrPeakHDRNits, 2000)
    }

    func testClampPercentAboveHundred() {
        let p = BrightnessPreferences(softwareZeroPercent: 150).clamped()
        XCTAssertEqual(p.softwareZeroPercent, 100)
    }

    func testClampPercentBelowZero() {
        let p = BrightnessPreferences(minHardwarePercent: -20).clamped()
        XCTAssertEqual(p.minHardwarePercent, 0)
    }

    func testClampNonFinitePercentFallsBack() {
        let p = BrightnessPreferences(dimmingSwitchoverPercent: .nan).clamped()
        XCTAssertEqual(p.dimmingSwitchoverPercent, BrightnessPreferences.standard.dimmingSwitchoverPercent)
    }

    func testClampUpscaleBelowHundredGoesToHundred() {
        let p = BrightnessPreferences(upscaleMaxPercent: 50).clamped()
        XCTAssertEqual(p.upscaleMaxPercent, 100)
    }

    func testClampUpscaleAboveThousandGoesToThousand() {
        let p = BrightnessPreferences(upscaleMaxPercent: 5000).clamped()
        XCTAssertEqual(p.upscaleMaxPercent, 1000)
    }

    func testClampedNeverHasInvertedOrOutOfRangeBounds() {
        let wild = BrightnessPreferences(
            hardwareMinNits: 900, hardwareMaxNits: -3,
            hdrPeakSDRNits: 1900, hdrPeakHDRNits: 100,
            softwareZeroPercent: 900, minHardwarePercent: -40,
            dimmingSwitchoverPercent: 400, upscaleMaxPercent: 1
        ).clamped()
        XCTAssertLessThanOrEqual(wild.hardwareMinNits, wild.hardwareMaxNits)
        XCTAssertLessThanOrEqual(wild.hdrPeakSDRNits, wild.hdrPeakHDRNits)
        for percent in [wild.softwareZeroPercent, wild.minHardwarePercent, wild.dimmingSwitchoverPercent] {
            XCTAssertGreaterThanOrEqual(percent, 0)
            XCTAssertLessThanOrEqual(percent, 100)
        }
        XCTAssertGreaterThanOrEqual(wild.upscaleMaxPercent, 100)
        XCTAssertLessThanOrEqual(wild.upscaleMaxPercent, 1000)
    }

    func testClampedIsIdempotent() {
        let once = BrightnessPreferences(hardwareMinNits: 900, hardwareMaxNits: 100, upscaleMaxPercent: 1).clamped()
        XCTAssertEqual(once.clamped(), once)
    }

    // MARK: - Curve monotonicity sweeps

    private func assertMonotonic(
        _ prefs: BrightnessPreferences,
        ceiling: Double = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var prevHardware = -Double.infinity
        var prevSoftware = -Double.infinity
        var prevUpscale = -Double.infinity
        var s = 0.0
        while s <= 1.0000001 {
            let out = BrightnessCurve.evaluate(s, preferences: prefs, hardwareCeiling: ceiling)
            XCTAssertGreaterThanOrEqual(out.hardware + 1e-9, prevHardware, "hardware must not decrease @ \(s)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(out.softwareDim + 1e-9, prevSoftware, "softwareDim must not decrease @ \(s)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(out.upscaleFactor + 1e-9, prevUpscale, "upscaleFactor must not decrease @ \(s)", file: file, line: line)
            prevHardware = out.hardware
            prevSoftware = out.softwareDim
            prevUpscale = out.upscaleFactor
            s += 0.01
        }
    }

    func testCurveIsMonotonicStandardProfile() {
        assertMonotonic(.standard)
    }

    func testCurveIsMonotonicHighSwitchover() {
        assertMonotonic(BrightnessPreferences(dimmingSwitchoverPercent: 90))
    }

    func testCurveIsMonotonicZeroSwitchover() {
        assertMonotonic(BrightnessPreferences(dimmingSwitchoverPercent: 0))
    }

    func testCurveIsMonotonicFullSwitchover() {
        assertMonotonic(BrightnessPreferences(dimmingSwitchoverPercent: 100))
    }

    func testCurveIsMonotonicWithFloors() {
        assertMonotonic(BrightnessPreferences(softwareZeroPercent: 20, minHardwarePercent: 10))
    }

    // MARK: - Hardware saturation before upscaling

    func testHardwareSaturatesAtSwitchover() {
        let prefs = BrightnessPreferences(dimmingSwitchoverPercent: 50)
        let justBelow = BrightnessCurve.evaluate(0.49, preferences: prefs)
        let atSwitchover = BrightnessCurve.evaluate(0.50, preferences: prefs)
        XCTAssertLessThan(justBelow.hardware, 1)
        XCTAssertEqual(atSwitchover.hardware, 1, accuracy: 1e-9)
    }

    func testHardwareIsOneThroughoutUpscalingZone() {
        var s = 0.5
        while s <= 1.0000001 {
            XCTAssertEqual(BrightnessCurve.evaluate(s).hardware, 1, accuracy: 1e-9, "hardware must stay saturated @ \(s)")
            s += 0.01
        }
    }

    func testHardwareNeverExceedsOne() {
        var s = 0.0
        while s <= 1.0000001 {
            let out = BrightnessCurve.evaluate(s)
            XCTAssertLessThanOrEqual(out.hardware, 1)
            XCTAssertGreaterThanOrEqual(out.hardware, 0)
            s += 0.01
        }
    }

    // MARK: - Software dimming at the bottom of the slider

    func testSoftwareDimAtZeroInputIsSoftwareZero() {
        let prefs = BrightnessPreferences(softwareZeroPercent: 20)
        XCTAssertEqual(BrightnessCurve.evaluate(0, preferences: prefs).softwareDim, 0.2, accuracy: 1e-9)
    }

    func testSoftwareDimAtZeroInputDefaultsToZero() {
        XCTAssertEqual(BrightnessCurve.evaluate(0).softwareDim, 0, accuracy: 1e-9)
    }

    func testSoftwareDimReachesOneAtSwitchover() {
        XCTAssertEqual(BrightnessCurve.evaluate(0.5).softwareDim, 1, accuracy: 1e-9)
    }

    func testSoftwareDimNonNegativeAcrossSweep() {
        var s = 0.0
        while s <= 1.0000001 {
            let out = BrightnessCurve.evaluate(s)
            XCTAssertGreaterThanOrEqual(out.softwareDim, 0)
            XCTAssertLessThanOrEqual(out.softwareDim, 1)
            s += 0.01
        }
    }

    // MARK: - Upscaling

    func testUpscaleFactorReachesMaxAtInputOne() {
        let prefs = BrightnessPreferences(upscaleMaxPercent: 350)
        XCTAssertEqual(BrightnessCurve.evaluate(1, preferences: prefs).upscaleFactor, 3.5, accuracy: 1e-9)
    }

    func testUpscaleFactorIsOneInDimmingZone() {
        var s = 0.0
        while s <= 0.5 + 1e-9 {
            XCTAssertEqual(BrightnessCurve.evaluate(s).upscaleFactor, 1, accuracy: 1e-9, "@ \(s)")
            s += 0.01
        }
    }

    func testUpscaleFactorNeverBelowOne() {
        var s = 0.0
        while s <= 1.0000001 {
            XCTAssertGreaterThanOrEqual(BrightnessCurve.evaluate(s).upscaleFactor, 1)
            s += 0.01
        }
    }

    // MARK: - Nits conversion

    func testSDRNitsRoundTrip() {
        var t = 0.0
        while t <= 1.0000001 {
            let nits = BrightnessCurve.sdrNits(fromScale: t)
            XCTAssertEqual(BrightnessCurve.sdrScale(fromNits: nits), t, accuracy: 1e-9, "@ \(t)")
            t += 0.05
        }
    }

    func testHDRNitsRoundTrip() {
        var t = 0.0
        while t <= 1.0000001 {
            let nits = BrightnessCurve.hdrNits(fromScale: t)
            XCTAssertEqual(BrightnessCurve.hdrScale(fromNits: nits), t, accuracy: 1e-9, "@ \(t)")
            t += 0.05
        }
    }

    func testHardwareNitsRoundTrip() {
        var t = 0.0
        while t <= 1.0000001 {
            let nits = BrightnessCurve.hardwareNits(fromScale: t)
            XCTAssertEqual(BrightnessCurve.hardwareScale(fromNits: nits), t, accuracy: 1e-9, "@ \(t)")
            t += 0.05
        }
    }

    func testSDRNitsSpanHardwareMinToSDRPeak() {
        XCTAssertEqual(BrightnessCurve.sdrNits(fromScale: 0), 4, accuracy: 1e-9)
        XCTAssertEqual(BrightnessCurve.sdrNits(fromScale: 1), 500, accuracy: 1e-9)
    }

    func testHDRNitsSpanHardwareMinToHDRPeak() {
        XCTAssertEqual(BrightnessCurve.hdrNits(fromScale: 0), 4, accuracy: 1e-9)
        XCTAssertEqual(BrightnessCurve.hdrNits(fromScale: 1), 1600, accuracy: 1e-9)
    }

    func testNitsOrderingSDRNeverAboveHDR() {
        var t = 0.0
        while t <= 1.0000001 {
            XCTAssertLessThanOrEqual(BrightnessCurve.sdrNits(fromScale: t), BrightnessCurve.hdrNits(fromScale: t), "@ \(t)")
            t += 0.05
        }
    }

    func testNitsHelpersClampOutOfRangeScale() {
        XCTAssertEqual(BrightnessCurve.sdrNits(fromScale: 2), BrightnessCurve.sdrNits(fromScale: 1), accuracy: 1e-9)
        XCTAssertEqual(BrightnessCurve.sdrNits(fromScale: -1), BrightnessCurve.sdrNits(fromScale: 0), accuracy: 1e-9)
        XCTAssertEqual(BrightnessCurve.hdrScale(fromNits: 1e9), 1, accuracy: 1e-9)
        XCTAssertEqual(BrightnessCurve.hdrScale(fromNits: -5), 0, accuracy: 1e-9)
    }

    // MARK: - No NaN / negative anywhere

    func testCurveOutputsFiniteNonNegativeAcrossSweep() {
        let profiles: [BrightnessPreferences] = [
            .standard,
            BrightnessPreferences(dimmingSwitchoverPercent: 0),
            BrightnessPreferences(dimmingSwitchoverPercent: 100),
            BrightnessPreferences(softwareZeroPercent: 30, minHardwarePercent: 15, upscaleMaxPercent: 500),
        ]
        for prefs in profiles {
            var s = 0.0
            while s <= 1.0000001 {
                let out = BrightnessCurve.evaluate(s, preferences: prefs, hardwareCeiling: 0)
                for (label, value) in [
                    ("hardware", out.hardware),
                    ("softwareDim", out.softwareDim),
                    ("upscaleFactor", out.upscaleFactor),
                    ("hardwareNits", out.hardwareNits),
                ] {
                    XCTAssertTrue(value.isFinite, "\(label) must be finite @ \(s)")
                    XCTAssertGreaterThanOrEqual(value, 0, "\(label) must not be negative @ \(s)")
                }
                s += 0.01
            }
        }
    }

    // MARK: - Hardware ceiling input

    func testHardwareNitsUsesCeilingWhenPositive() {
        let out = BrightnessCurve.evaluate(1, preferences: .standard, hardwareCeiling: 800)
        XCTAssertEqual(out.hardwareNits, 800, accuracy: 1e-9)
        let mid = BrightnessCurve.evaluate(1, preferences: .standard, hardwareCeiling: 800)
        XCTAssertEqual(mid.hardwareNits, 800, accuracy: 1e-9)
    }

    func testHardwareNitsFallsBackWhenCeilingNonPositive() {
        let out = BrightnessCurve.evaluate(1, preferences: .standard, hardwareCeiling: 0)
        XCTAssertEqual(out.hardwareNits, 500, accuracy: 1e-9)
    }

    // MARK: - Settings-backed persistence

    func testSettingsUnsetReturnsStandard() {
        Settings.defaults.removeObject(forKey: prefsKey)
        XCTAssertEqual(Settings.brightnessPreferences, .standard)
    }

    func testSettingsBrightnessPreferencesRoundTrip() {
        var prefs = BrightnessPreferences(hardwareMaxNits: 250, dimmingSwitchoverPercent: 40)
        prefs.preferHardwareControl = false
        Settings.brightnessPreferences = prefs
        XCTAssertEqual(Settings.brightnessPreferences, prefs.clamped())
    }
}
