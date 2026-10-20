import XCTest
@testable import FBDCore

// MARK: - Fakes (the ExternalControlling pattern, applied to each seam)

private final class FakeApple: AppleControlling {
    var read: Double? = nil
    var writeCalls = 0
    var lastWrite: Double = 0

    /// Models a hardware read-back: returns the last written value unless
    /// the test overrides `read`.
    func getBrightness(for display: Display) -> Double? { read ?? lastWrite }
    func setBrightness(_ value: Double, on display: Display) {
        writeCalls += 1
        lastWrite = value
    }
}

private final class FakeDDC: DDCControlling {
    var read: Double? = nil
    var writeCalls = 0
    var lastWrite: (DDCFeature, Double) = (.brightness, 0)

    func getFeature(_ feature: DDCFeature, for display: Display) -> Double? {
        feature == .brightness ? read : nil
    }
    @discardableResult
    func setFeature(_ feature: DDCFeature, value: Double, for display: Display) -> Bool {
        writeCalls += 1
        lastWrite = (feature, value)
        return true
    }
}

/// Mimics XDRNativeController's contract: on success it is the native path's
/// state updater (display.updateSoftwareBoost). Failure leaves state alone.
private final class FakeXDR: XDRUpscaling {
    var available = true
    /// Scripted setUpscaleTarget outcomes; consumed in order (last repeats).
    var writeOutcomes: [Bool] = []
    var writeCalls = 0
    var disableCalls = 0
    private(set) var lastTarget: Int?
    var currentTarget: Int?
    /// Where the live software-boost sessions come from — wired in by
    /// `CombinedBrightness`.
    private(set) var softwareBoostProvider: () -> [CGDirectDisplayID] = { [] }

    func isAvailable(for display: Display) -> Bool { available }

    @discardableResult
    func setUpscaleTarget(_ nits: Int, for display: Display) -> Bool {
        writeCalls += 1
        lastTarget = nits
        let ok = writeOutcomes.isEmpty ? true : writeOutcomes[min(writeCalls - 1, writeOutcomes.count - 1)]
        if ok {
            currentTarget = nits
            // The native path's claim: the preset is on screen, not the
            // software boost.
            updateNativeState(display, upscaled: true, targetNits: nits)
        }
        return ok
    }

    @discardableResult
    func disableUpscaling(for display: Display) -> Bool {
        disableCalls += 1
        currentTarget = nil
        updateNativeState(display, upscaled: false, targetNits: nil)
        return true
    }

    func upscaleTarget(for display: Display) -> Int? { currentTarget }

    func setSoftwareBoostProvider(_ provider: @escaping () -> [CGDirectDisplayID]) {
        softwareBoostProvider = provider
    }

    /// The native controller's state update — the claim belongs to the
    /// preset, not to the software boost.
    private func updateNativeState(_ display: Display, upscaled: Bool, targetNits: Int?) {
        display.updateXDRState(
            presets: display.presets,
            isXDRCapable: display.isXDRCapable,
            activePresetIndex: display.activePresetIndex,
            isXDRUpscaled: upscaled,
            xdrUpscaleTargetNits: targetNits,
            isHDRModeCapable: display.isHDRModeCapable,
            isHDRModeEnabled: display.isHDRModeEnabled
        )
    }
}

@MainActor
private final class FakeOverlay: OverlayControlling {
    var accepts = true
    var boostCalls: [(factor: Double, displayID: CGDirectDisplayID)] = []
    var dimCalls: [(factor: Double, displayID: CGDirectDisplayID)] = []
    /// The below-floor blend factor requested, per display.
    var blendCalls: [(factor: Double, displayID: CGDirectDisplayID)] = []
    /// Whether the surface claims a dim set here would outlive the call. The app's overlay does;
    /// a one-shot CLI's does not, which is the case worth testing.
    var softwareDimPersists = true
    /// The displays with a live session — the overlay's own answer to "is a
    /// boost on screen right now?".
    var activeSessions: [CGDirectDisplayID] = []
    /// Called when a session ends.
    var onSessionEnded: ((CGDirectDisplayID) -> Void)?

    @discardableResult
    func setSoftwareBoost(_ factor: Double, displayID: CGDirectDisplayID) -> Bool {
        boostCalls.append((factor, displayID))
        guard accepts else { return false }
        if factor > 1 {
            if !activeSessions.contains(displayID) { activeSessions.append(displayID) }
        } else if let index = activeSessions.firstIndex(of: displayID) {
            // Releasing the boost ends the session: the overlay says so, so
            // the claim that mirrored it can go with it.
            activeSessions.remove(at: index)
            onSessionEnded?(displayID)
        }
        return true
    }

    @discardableResult
    func setSoftwareDim(_ factor: Double, displayID: CGDirectDisplayID) -> Bool {
        dimCalls.append((factor, displayID))
        return accepts
    }

    @discardableResult
    func setBrightnessBlendFactor(_ factor: Double, displayID: CGDirectDisplayID) -> Bool {
        blendCalls.append((factor, displayID))
        return accepts
    }

    func activeBoostDisplayIDs() -> [CGDirectDisplayID] { activeSessions }
}

// MARK: - Fixture

@MainActor
final class CombinedBrightnessTests: XCTestCase {
    private var apple = FakeApple()
    private var ddc = FakeDDC()
    private var xdr = FakeXDR()
    private var overlay = FakeOverlay()
    private var module: CombinedBrightness!
    private var display: Display!

    private var savedCombined: Bool!
    private var savedSoftware: Bool!
    private var savedTarget: Int!
    private var savedPreferences: BrightnessPreferences!
    private var savedFloorBlendEnabled: Bool!
    private var savedFloorBlendThreshold: Double!

    override func setUp() {
        super.setUp()
        savedCombined = Settings.combinedBrightnessEnabled
        savedSoftware = Settings.softwareUpscalingEnabled
        savedTarget = Settings.xdrUpscaleTargetNits
        savedPreferences = Settings.brightnessPreferences
        savedFloorBlendEnabled = Settings.brightnessFloorBlendEnabled
        savedFloorBlendThreshold = Settings.brightnessFloorBlendThresholdPercent
        apple = FakeApple()
        ddc = FakeDDC()
        xdr = FakeXDR()
        overlay = FakeOverlay()
        module = CombinedBrightness(apple: apple, ddc: ddc, xdr: xdr, overlay: overlay)
        display = Display(
            id: 42,
            name: "Test Display",
            isBuiltin: false,
            vendorNumber: 0x10AC,
            modelNumber: 0x1234,
            serialNumber: 0x5678,
            bounds: .zero,
            isOnline: true,
            isActive: true
        )
        // Hardware ceiling 500 nits; HDR ceiling 1600 nits; slider top 1600.
        let presets = [
            XDRPreset(
                index: 0, name: "Preset 1", isValid: true, isWritable: false,
                maxSDRLuminance: 500, maxHDRLuminance: 1600, maxSliderBrightness: 500,
                minSliderBrightness: 2, edrHeadroom: 16, uniqueID: nil, raw: [:]
            ),
        ]
        display.updateXDRState(
            presets: presets, isXDRCapable: true, activePresetIndex: 0,
            isXDRUpscaled: false, xdrUpscaleTargetNits: nil,
            isHDRModeCapable: false, isHDRModeEnabled: false
        )
        display.updateAppleBrightnessStatus(available: true)
        // No explicit apple.read: FakeApple models a hardware read-back of
        // the last write.
        Settings.combinedBrightnessEnabled = true
        Settings.softwareUpscalingEnabled = true
        Settings.xdrUpscaleTargetNits = 1600
        // Reset the model profile so every case starts from the shipped
        // default; tests that exercise a profile set it explicitly.
        Settings.brightnessPreferences = .standard
        // The below-floor blend is off unless a case turns it on.
        Settings.brightnessFloorBlendEnabled = false
        Settings.brightnessFloorBlendThresholdPercent = 15
        Settings.setFloorBlend(nil, for: display.identityKey)
    }

    override func tearDown() {
        // Restore the real values — writes through @Storage hit the live
        // defaults suite, so a hardcoded tearDown would pollute the app.
        Settings.combinedBrightnessEnabled = savedCombined
        Settings.softwareUpscalingEnabled = savedSoftware
        Settings.xdrUpscaleTargetNits = savedTarget
        Settings.brightnessPreferences = savedPreferences
        Settings.brightnessFloorBlendEnabled = savedFloorBlendEnabled
        Settings.brightnessFloorBlendThresholdPercent = savedFloorBlendThreshold
        Settings.setFloorBlend(nil, for: display.identityKey)
        super.tearDown()
    }

    // MARK: - Below the hardware ceiling

    func testHardwareBranchTearsDownUpscalingAndSyncsStateOff() {
        display.updateSoftwareBoost(true, targetNits: 800)

        XCTAssertTrue(module.set(0.2, on: display))

        XCTAssertEqual(xdr.disableCalls, 1, "active upscaling must be torn down")
        XCTAssertEqual(overlay.boostCalls.last?.factor, 1, "overlay must be stopped")
        // 0.2 × 1600 nits = 320 nits = 64% of the 500-nit hardware ceiling.
        XCTAssertEqual(apple.lastWrite, 0.64, accuracy: 0.001)
        XCTAssertFalse(display.isXDRUpscaled, "below the ceiling, upscale state is off")
        XCTAssertNil(display.xdrUpscaleTargetNits)
        XCTAssertEqual(module.get(for: display) ?? -1, 0.64, accuracy: 0.001)
    }

    func testNonCombinedModeWritesHardwareOnly() {
        Settings.combinedBrightnessEnabled = false
        xdr.available = true

        XCTAssertTrue(module.set(0.5, on: display))

        XCTAssertEqual(apple.writeCalls, 1)
        XCTAssertEqual(xdr.writeCalls, 0)
        XCTAssertEqual(overlay.boostCalls.count, 0)
        XCTAssertFalse(display.isXDRUpscaled)
    }

    // MARK: - Above the hardware ceiling

    func testNativeUpscaleBranchEngagesNativeAndSyncsState() {
        // 0.5 × 1600 = 800 nits > 500 hardware ceiling → native upscale.
        XCTAssertTrue(module.set(0.5, on: display))

        XCTAssertEqual(xdr.lastTarget, 800)
        XCTAssertEqual(overlay.boostCalls.count, 0)
        XCTAssertTrue(display.isXDRUpscaled)
        XCTAssertEqual(display.xdrUpscaleTargetNits, 800)
        // Read-back agrees: 800 / 1600 = 0.5.
        XCTAssertEqual(module.get(for: display) ?? -1, 0.5, accuracy: 0.001)
    }

    func testSoftwareBoostBranchSyncsStateOn() {
        xdr.available = false

        XCTAssertTrue(module.set(0.5, on: display))

        XCTAssertEqual(overlay.boostCalls.last?.factor ?? 0, 1.6, accuracy: 0.001) // 800/500
        XCTAssertTrue(display.isXDRUpscaled)
        XCTAssertEqual(display.xdrUpscaleTargetNits, 800)
        // The read-back regression: get() must report the boost, not hardware.
        XCTAssertEqual(module.get(for: display) ?? -1, 0.5, accuracy: 0.001)
    }

    func testSoftwareBoostBranchLeavesStateOffWhenOverlayRejects() {
        xdr.available = false
        overlay.accepts = false

        XCTAssertFalse(module.set(0.5, on: display))

        XCTAssertFalse(display.isXDRUpscaled)
        XCTAssertNil(display.xdrUpscaleTargetNits)
    }

    func testSetTargetFailsWhenSoftwareDisabled() {
        xdr.available = false
        Settings.softwareUpscalingEnabled = false

        XCTAssertFalse(module.setTarget(800, on: display))
        XCTAssertFalse(display.isXDRUpscaled)
        XCTAssertNil(display.xdrUpscaleTargetNits)
    }

    // MARK: - Explicit nits target (`xdr <id> <nits>`)

    func testSetTargetFallsBackToOverlayWhenNativeWriteFails() {
        xdr.available = true
        xdr.writeOutcomes = [false]

        XCTAssertTrue(module.setTarget(800, on: display))

        XCTAssertEqual(overlay.boostCalls.last?.factor ?? 0, 1.6, accuracy: 0.001)
        XCTAssertTrue(display.isXDRUpscaled)
        XCTAssertEqual(display.xdrUpscaleTargetNits, 800)
    }

    func testSetTargetNilDisablesAndSyncsOff() {
        display.updateSoftwareBoost(true, targetNits: 800)

        XCTAssertTrue(module.setTarget(nil, on: display))

        XCTAssertEqual(xdr.disableCalls, 1)
        XCTAssertEqual(overlay.boostCalls.last?.factor, 1)
        XCTAssertFalse(display.isXDRUpscaled)
        XCTAssertNil(display.xdrUpscaleTargetNits)
    }

    func testSetTargetBelowCeilingEngagesNativeWhenAvailable() {
        // Behavior-preserving: the explicit nits command routes to native
        // upscaling whenever available, even below the hardware ceiling
        // (XDRNativeController clamps/validates the actual preset write).
        XCTAssertTrue(module.setTarget(300, on: display))
        XCTAssertEqual(xdr.lastTarget, 300)
        XCTAssertTrue(display.isXDRUpscaled)
    }

    // MARK: - Brightness-model preferences (BetterDisplay parity)

    func testDefaultEffectivePreferencesIsStandard() {
        XCTAssertEqual(module.effectivePreferences, .standard)
    }

    func testInjectedStandardPreferencesReproduceLegacyRoute() {
        let injected = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay, preferences: .standard
        )

        XCTAssertTrue(injected.set(0.2, on: display))

        // Identical to the no-preferences route: 0.2 × 1600 = 320 nits stays
        // under the 500-nit ceiling, so it writes hardware.
        XCTAssertEqual(apple.lastWrite, 0.64, accuracy: 0.001)
        XCTAssertEqual(xdr.writeCalls, 0)
    }

    func testInjectedProfileCapsHardwareCeiling() {
        // hardwareMaxNits 250 < the display's 500 → 0.2 × 1600 = 320 nits now
        // exceeds the ceiling, so the route tilts to native upscaling.
        let injected = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: BrightnessPreferences(hardwareMaxNits: 250)
        )

        XCTAssertTrue(injected.set(0.2, on: display))

        XCTAssertEqual(xdr.lastTarget, 320)
        XCTAssertTrue(display.isXDRUpscaled)
    }

    func testInjectedProfileCapsTopAtHDRPeak() {
        // hdrPeakHDRNits 800 caps the combined top to 800 nits, so 0.8 ⇒ 640.
        let injected = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: BrightnessPreferences(hdrPeakHDRNits: 800)
        )

        XCTAssertTrue(injected.set(0.8, on: display))

        XCTAssertEqual(xdr.lastTarget, 640)
    }

    func testStoredPreferencesFeedTheRoute() {
        Settings.brightnessPreferences = BrightnessPreferences(hardwareMaxNits: 250)

        // A module with no injected profile must pick up the stored one.
        let stored = CombinedBrightness(apple: apple, ddc: ddc, xdr: xdr, overlay: overlay)
        XCTAssertEqual(stored.effectivePreferences.hardwareMaxNits, 250)

        XCTAssertTrue(stored.set(0.2, on: display))
        XCTAssertEqual(xdr.lastTarget, 320)
    }

    func testSetTargetUsesInjectedPreferencesHDRPeakCap() {
        // An explicit 1200-nit target is capped to the profile's 800-nit peak.
        let injected = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: BrightnessPreferences(hdrPeakHDRNits: 800)
        )

        XCTAssertTrue(injected.setTarget(1200, on: display))

        XCTAssertEqual(xdr.lastTarget, 800)
    }

    // MARK: - The curve's knobs (row 10)

    /// A profile that carries no *curve* knob still routes through the planner's linear
    /// factor, so wiring the curve cannot have moved anyone who only touched the nits
    /// fields: 1000-nit peak against the fixture's 500-nit hardware ceiling is exactly 2.0.
    func testAProfileWithOnlyNitsKnobsStillUsesThePlannerFactor() {
        xdr.available = false
        let injected = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: BrightnessPreferences(hdrPeakHDRNits: 1000)
        )

        XCTAssertTrue(injected.set(1.0, on: display))

        XCTAssertEqual(overlay.boostCalls.last?.factor ?? 0, 2.0, accuracy: 1e-9)
    }

    /// `upscaleMaxPercent` used to shape nothing at all. It now caps how far a software
    /// boost goes — the curve's own job, and the reason it was written. The planner alone
    /// would have asked for 1600/500 = 3.2 on this fixture.
    func testUpscaleMaxPercentCapsTheSoftwareBoostFactor() {
        xdr.available = false
        let capped = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: BrightnessPreferences(upscaleMaxPercent: 150)
        )

        XCTAssertTrue(capped.set(1.0, on: display))

        XCTAssertEqual(overlay.boostCalls.last?.factor ?? 0, 1.5, accuracy: 1e-9)
    }

    /// `dimmingSwitchoverPercent` decides *where* the curve's upscaling begins, so moving
    /// it must change how much of the ramp is done at the same slider position.
    func testDimmingSwitchoverPercentMovesWhereTheBoostRamps() {
        xdr.available = false
        let late = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: BrightnessPreferences(dimmingSwitchoverPercent: 80)
        )
        XCTAssertTrue(late.set(0.85, on: display))
        let lateFactor = overlay.boostCalls.last?.factor ?? 0

        overlay.boostCalls.removeAll()
        let early = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: BrightnessPreferences(dimmingSwitchoverPercent: 40)
        )
        XCTAssertTrue(early.set(0.85, on: display))
        let earlyFactor = overlay.boostCalls.last?.factor ?? 0

        XCTAssertGreaterThan(lateFactor, 1, "0.85 is past both switchovers, so a boost happens either way")
        XCTAssertLessThan(
            lateFactor, earlyFactor,
            "starting the ramp later must leave less of it done at the same slider position"
        )
    }

    /// The ceiling applies to the native path as well, and that is the path usually doing
    /// the boosting: 150% of the fixture's 500-nit hardware ceiling is 750, so a slider
    /// pushed to the 1600-nit top is capped there.
    func testUpscaleMaxPercentCapsTheNativeUpscaleTarget() {
        let capped = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: BrightnessPreferences(upscaleMaxPercent: 150)
        )

        XCTAssertTrue(capped.set(1.0, on: display))

        XCTAssertEqual(xdr.lastTarget, 750)
    }

    /// The same slider with no curve knob still reaches the top, so 750 is the knob's doing
    /// rather than a new ceiling. Uses an explicit standard profile: `nil` would read the
    /// machine's stored model, which a test must not depend on.
    func testTheNativeTargetIsUncappedWithoutACurveKnob() {
        let plain = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: .standard
        )

        XCTAssertTrue(plain.set(1.0, on: display))

        XCTAssertEqual(xdr.lastTarget, 1600)
    }

    // MARK: - The read agrees with the screen (row 9 / 10's shared piece)

    /// The point of tracking the dim: `get` reports what the screen shows rather than only what
    /// the backlight is doing, so nothing downstream reads a value the display disagrees with.
    func testGetReportsTheEffectiveBrightnessWhenADimIsInForce() {
        apple.read = 0.8
        display.updateSoftwareDim(0.5)

        XCTAssertEqual(module.get(for: display) ?? -1, 0.4, accuracy: 1e-9)
    }

    /// With nothing dimming the read is the hardware value, exactly as it always was — wiring
    /// this must not move the ordinary case.
    func testGetIsTheHardwareValueWhenNothingDims() {
        apple.read = 0.8
        XCTAssertEqual(display.softwareDim, 1, "a display starts undimmed")

        XCTAssertEqual(module.get(for: display) ?? -1, 0.8, accuracy: 1e-9)
    }

    /// `get` still means "no control path" by returning nil, which the dim must not turn into a
    /// number: a display FBD cannot read has no brightness to report, dimmed or not.
    func testGetStillReturnsNilWithoutAControlPath() {
        let unreachable = Display(
            id: 43,
            name: "No path",
            isBuiltin: false,
            vendorNumber: 1,
            modelNumber: 2,
            serialNumber: 3,
            bounds: .zero,
            isOnline: true,
            isActive: true
        )
        unreachable.updateSoftwareDim(0.5)

        XCTAssertNil(module.get(for: unreachable))
    }

    /// The lock/dim-to-black path is a *different* source: it writes the overlay, never the
    /// display's tracked dim, so it cannot move a brightness read. The control source is written
    /// with 0 here — passing anything else would create a real overlay window over a real screen
    /// from inside a unit test, and nothing in the test would remove it.
    func testTheControlDimDoesNotWriteTheTrackedBrightnessDim() {
        apple.read = 0.8
        display.updateSoftwareDim(0.5)
        let before = module.get(for: display)

        let overlay = OverlayController()
        overlay.setDimFactor(0, displayID: display.id)

        XCTAssertEqual(display.softwareDim, 0.5, accuracy: 1e-9, "the control path does not write the tracked dim")
        XCTAssertEqual(module.get(for: display) ?? -1, before ?? -1, accuracy: 1e-9, "so a brightness read cannot move")
    }

    // MARK: - The two routes the dim exists for (row 9's prefer-software, row 10's dimming zone)

    /// Prefer-software: the request is delivered as a dim over the backlight, so the slider is
    /// not on the hardware write path — and the read round-trips, which is the whole point.
    func testPreferSoftwareDeliversTheRequestAsADimWithoutTouchingTheHardware() {
        apple.read = 0.8
        let module = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: BrightnessPreferences(preferHardwareControl: false)
        )

        XCTAssertTrue(module.set(0.25, on: display))

        XCTAssertEqual(overlay.dimCalls.last?.factor ?? -1, 0.3125, accuracy: 1e-9, "0.25 of a 0.8 backlight")
        XCTAssertEqual(apple.writeCalls, 0, "the hardware is exactly what prefer-software avoids writing")
        XCTAssertEqual(display.softwareDim, 0.3125, accuracy: 1e-9)
        XCTAssertEqual(module.get(for: display) ?? -1, 0.25, accuracy: 1e-9, "the read round-trips the request")
    }

    /// A dim can only lower what the screen shows, so a request *above* the backlight still needs
    /// the hardware. Falling back is the honest answer; a dim there would silently under-deliver.
    func testPreferSoftwareFallsBackToHardwareAboveTheBacklight() {
        apple.read = 0.2
        let module = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: BrightnessPreferences(preferHardwareControl: false)
        )

        XCTAssertTrue(module.set(0.3, on: display))

        XCTAssertEqual(apple.writeCalls, 1, "0.3 of a 0.2 backlight cannot be reached by dimming")
        XCTAssertEqual(apple.lastWrite, 0.96, accuracy: 1e-9, "so the planner's fraction is written")
        XCTAssertEqual(display.softwareDim, 1, accuracy: 1e-9)
        XCTAssertEqual(overlay.dimCalls.last?.factor ?? -1, 1, accuracy: 1e-9, "and no dim is left in force")
    }

    /// A dim that only the app can hold must not be taken elsewhere: the CLI keeps the hardware
    /// route it has always used rather than accepting a write that would vanish with the process.
    func testATransientOverlayKeepsToTheHardwareRoute() {
        apple.read = 0.8
        overlay.softwareDimPersists = false
        let module = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: BrightnessPreferences(preferHardwareControl: false)
        )

        XCTAssertTrue(module.set(0.25, on: display))

        XCTAssertEqual(apple.writeCalls, 1, "the hardware path still delivers the request")
        XCTAssertEqual(apple.lastWrite, 0.8, accuracy: 1e-9)
        XCTAssertEqual(display.softwareDim, 1, accuracy: 1e-9)
    }

    /// The curve's dimming zone: the model ramps the hardware *and* dims the rest, so both halves
    /// have to be applied or the screen lands at the wrong level.
    func testTheCurvesDimmingZoneAppliesBothHalves() {
        let module = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: BrightnessPreferences(minHardwarePercent: 20)
        )

        XCTAssertTrue(module.set(0.25, on: display))

        // Half way up the dimming zone: hardware 0.2 + 0.8 × 0.5, dim 0 → 1 × 0.5.
        XCTAssertEqual(apple.lastWrite, 0.6, accuracy: 1e-9, "the hardware ramps with the curve")
        XCTAssertEqual(overlay.dimCalls.last?.factor ?? -1, 0.5, accuracy: 1e-9, "and the dim supplies the rest")
        XCTAssertEqual(display.softwareDim, 0.5, accuracy: 1e-9)
        // The read is what the screen shows — the model's own mapping, not the slider position.
        XCTAssertEqual(module.get(for: display) ?? -1, 0.3, accuracy: 1e-9)
    }

    /// Once the slider is above the ceiling the curve keeps dimming off, and a boost with a dim
    /// left over would fight it — so the dim is released rather than left dimming the screen.
    func testADimIsReleasedWhenTheRouteLeavesTheDimmingZone() {
        let module = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: BrightnessPreferences(minHardwarePercent: 20)
        )

        XCTAssertTrue(module.set(0.25, on: display))
        XCTAssertEqual(display.softwareDim, 0.5, accuracy: 1e-9, "the dimming zone dimmed it")

        XCTAssertTrue(module.set(1.0, on: display))

        XCTAssertEqual(display.softwareDim, 1, accuracy: 1e-9, "the upscaling zone does not dim")
        XCTAssertEqual(overlay.dimCalls.last?.factor ?? -1, 1, accuracy: 1e-9)
    }

    /// The shipped profile takes neither route, so a default install behaves exactly as it did:
    /// the hardware fraction is written and no dim is applied.
    func testTheShippedProfileStillAppliesNoDim() {
        apple.read = 0.8
        let module = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: .standard
        )

        XCTAssertTrue(module.set(0.25, on: display))

        XCTAssertEqual(apple.lastWrite, 0.8, accuracy: 1e-9, "the planner's fraction, unchanged")
        XCTAssertEqual(display.softwareDim, 1, accuracy: 1e-9)
        XCTAssertEqual(module.get(for: display) ?? -1, 0.8, accuracy: 1e-9)
    }

    // MARK: - Slider path falls back when the native write fails

    func testSliderFallsBackToSoftwareBoostWhenNativeWriteFails() {
        xdr.writeOutcomes = [false]

        XCTAssertTrue(module.set(0.5, on: display))

        XCTAssertEqual(overlay.boostCalls.last?.factor ?? 0, 1.6, accuracy: 0.001) // 800/500
        XCTAssertTrue(display.isXDRUpscaled)
        XCTAssertEqual(display.xdrUpscaleTargetNits, 800)
    }

    func testSliderNativeFailureStaysFailedWhenSoftwareDisabled() {
        xdr.writeOutcomes = [false]
        Settings.softwareUpscalingEnabled = false

        XCTAssertFalse(module.set(0.5, on: display))
        XCTAssertTrue(overlay.boostCalls.isEmpty)
        XCTAssertFalse(display.isXDRUpscaled)
    }

    // MARK: - The below-floor blend

    /// With the blend on, a request under the threshold pins the hardware at
    /// the threshold and lets the software layer carry the rest.
    func testBlendPinsTheHardwareAndLetsTheSoftwareCarryTheRest() {
        Settings.combinedBrightnessEnabled = false
        Settings.brightnessFloorBlendEnabled = true
        Settings.brightnessFloorBlendThresholdPercent = 15

        XCTAssertTrue(module.set(0.05, on: display))

        XCTAssertEqual(apple.lastWrite, 0.15, accuracy: 1e-9,
                       "the hardware sits at the threshold, not at the request")
        XCTAssertEqual(overlay.blendCalls.last?.factor ?? -1, 0.05 / 0.15, accuracy: 1e-9)
        XCTAssertEqual(display.floorBlendFactor, 0.05 / 0.15, accuracy: 1e-9)
    }

    /// The read-back has to report the position the user asked for, not the
    /// panel's floor — the hardware is pinned, so it cannot report it itself.
    func testBlendReadBackReportsTheLogicalPosition() {
        Settings.combinedBrightnessEnabled = false
        Settings.brightnessFloorBlendEnabled = true

        XCTAssertTrue(module.set(0, on: display))

        XCTAssertEqual(module.get(for: display) ?? -1, 0, accuracy: 1e-9,
                       "0 % must not read back as the panel's floor")
    }

    /// Above the threshold the blend steps aside: the hardware carries the
    /// request and no software dim is left over.
    func testBlendStandsAsideAboveTheThreshold() {
        Settings.combinedBrightnessEnabled = false
        Settings.brightnessFloorBlendEnabled = true

        XCTAssertTrue(module.set(0.05, on: display))
        XCTAssertTrue(module.set(0.5, on: display))

        XCTAssertEqual(apple.lastWrite, 0.5, accuracy: 1e-9)
        XCTAssertEqual(overlay.blendCalls.last?.factor ?? -1, 1, accuracy: 1e-9,
                       "the software dim must be released above the threshold")
        XCTAssertEqual(display.floorBlendFactor, 1, accuracy: 1e-9)
    }

    /// A one-shot CLI invocation has no overlay that outlives it: pinning the
    /// hardware with nothing left to dim it would leave the screen brighter
    /// than the slider says, so the blend must not engage there.
    func testBlendIsSkippedWhenTheOverlayDoesNotOutliveTheCall() {
        Settings.combinedBrightnessEnabled = false
        Settings.brightnessFloorBlendEnabled = true
        overlay.softwareDimPersists = false

        XCTAssertTrue(module.set(0.05, on: display))

        XCTAssertEqual(apple.lastWrite, 0.05, accuracy: 1e-9,
                       "the request is written as-is when nothing can dim it afterwards")
        XCTAssertTrue(overlay.blendCalls.allSatisfy { $0.factor >= 1 },
                      "the blend must not engage when nothing can dim the screen afterwards")
        XCTAssertEqual(display.floorBlendFactor, 1, accuracy: 1e-9)
    }

    /// With the blend off nothing changes: the hardware carries the request
    /// and the read-back is the hardware's own.
    func testBlendOffLeavesTheRouteUntouched() {
        Settings.combinedBrightnessEnabled = false
        Settings.brightnessFloorBlendEnabled = false

        XCTAssertTrue(module.set(0.05, on: display))

        XCTAssertEqual(apple.lastWrite, 0.05, accuracy: 1e-9)
        XCTAssertTrue(overlay.blendCalls.allSatisfy { $0.factor >= 1 },
                      "with the blend off the software layer stays neutral")
        XCTAssertEqual(module.get(for: display) ?? -1, 0.05, accuracy: 1e-9)
    }

    /// A per-display override wins over the global switch.
    func testPerDisplayOverrideWinsOverTheGlobalSwitch() {
        Settings.combinedBrightnessEnabled = false
        Settings.brightnessFloorBlendEnabled = false
        Settings.setFloorBlend(
            BrightnessFloorBlend(threshold: 0.2, isEnabled: true),
            for: display.identityKey
        )

        XCTAssertTrue(module.set(0.1, on: display))

        XCTAssertEqual(apple.lastWrite, 0.2, accuracy: 1e-9)
        XCTAssertEqual(overlay.blendCalls.last?.factor ?? -1, 0.5, accuracy: 1e-9)
    }

    /// In HDR the DDC scale does not describe the panel, so the software layer
    /// carries the whole range and the hardware is left alone.
    func testHDRLeavesTheHardwareAloneAndCarriesTheRangeInSoftware() {
        Settings.combinedBrightnessEnabled = false
        Settings.brightnessFloorBlendEnabled = true
        display.updateXDRState(
            presets: [], isXDRCapable: true, activePresetIndex: nil,
            isXDRUpscaled: false, xdrUpscaleTargetNits: nil,
            isHDRModeCapable: true, isHDRModeEnabled: true
        )

        XCTAssertTrue(module.set(0.4, on: display))

        XCTAssertEqual(apple.writeCalls, 0, "the DDC scale says nothing about HDR")
        XCTAssertEqual(overlay.blendCalls.last?.factor ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(module.get(for: display) ?? -1, 0.4, accuracy: 1e-9)
    }

    // MARK: - The blend's contract

    /// The whole point of the blend: a request of 5 % dims the screen to 5 %
    /// and reads back as 5 % — not the panel's floor, and not a stale value.
    func testBlendRequestOfFivePercentDimsTheScreenAndReadsBackFivePercent() {
        Settings.combinedBrightnessEnabled = false
        Settings.brightnessFloorBlendEnabled = true
        Settings.brightnessFloorBlendThresholdPercent = 15

        XCTAssertTrue(module.set(0.05, on: display))

        XCTAssertEqual(apple.lastWrite, 0.15, accuracy: 1e-9,
                       "the hardware is pinned at the threshold")
        XCTAssertEqual(overlay.blendCalls.last?.factor ?? -1, 0.05 / 0.15, accuracy: 1e-9,
                       "the software layer carries the rest")
        XCTAssertEqual(display.floorBlendFactor, 0.05 / 0.15, accuracy: 1e-9)
        XCTAssertEqual(module.get(for: display) ?? -1, 0.05, accuracy: 1e-9,
                       "the read-back reports the position the user asked for")
    }

    /// The write lands asynchronously, so the read-back right after it can
    /// still show the value from before the write. The blend's own factor
    /// carries the position, so that stale value must not become the
    /// read-back.
    func testTheReadBackIsNotTheStaleHardwareValue() {
        Settings.combinedBrightnessEnabled = false
        Settings.brightnessFloorBlendEnabled = true
        apple.read = 0.6259

        XCTAssertTrue(module.set(0.05, on: display))

        XCTAssertEqual(module.get(for: display) ?? -1, 0.05, accuracy: 1e-9,
                       "a stale hardware read must not become the read-back")
    }

    /// The display model must not fall back to the floor either: the
    /// hardware-change notification that follows the pinned write reports the
    /// floor, and the slider must not jump to it.
    func testTheModelKeepsTheLogicalPositionWhileTheBlendPinsTheHardware() {
        Settings.combinedBrightnessEnabled = false
        Settings.brightnessFloorBlendEnabled = true

        XCTAssertTrue(module.set(0.05, on: display))

        // The hardware reports the pinned floor — that is what it was told to
        // be — and the model keeps the position the user asked for.
        display.updateBrightness(0.15)

        XCTAssertEqual(display.brightness ?? -1, 0.05, accuracy: 1e-9,
                       "the model must not fall back to the panel's floor")
    }

    /// The software dim route must not swallow a request the blend is there to
    /// deliver: it used to release the blend and serve the request the plain
    /// way, which left the screen at the panel's floor while the slider said
    /// otherwise.
    func testTheSoftwareDimRouteDoesNotSwallowTheBlend() {
        Settings.combinedBrightnessEnabled = true
        Settings.brightnessFloorBlendEnabled = true
        Settings.brightnessFloorBlendThresholdPercent = 20
        apple.read = 0.6259
        // A profile that takes the software dim route.
        let module = CombinedBrightness(
            apple: apple, ddc: ddc, xdr: xdr, overlay: overlay,
            preferences: BrightnessPreferences(preferHardwareControl: false)
        )

        XCTAssertTrue(module.set(0.05, on: display))

        // 0.05 of the 1600-nit slider is 80 nits — 16 % of the 500-nit
        // hardware scale, below the 20 % threshold, so the blend takes it.
        XCTAssertEqual(apple.lastWrite, 0.2, accuracy: 1e-9,
                       "the hardware is pinned at the threshold")
        XCTAssertEqual(overlay.blendCalls.last?.factor ?? -1, 0.16 / 0.2, accuracy: 1e-9,
                       "the blend carries the request, not the dim")
        XCTAssertEqual(display.softwareDim, 1, accuracy: 1e-9,
                       "only one software dim can be in force: the dim stands aside")
        XCTAssertEqual(overlay.dimCalls.last?.factor ?? -1, 1, accuracy: 1e-9)
    }

    /// Fail-closed: if the overlay refuses the factor the request goes to the
    /// hardware unchanged and no blend is reported, so the screen is never
    /// left brighter than the slider says.
    func testBlendFallsBackToTheHardwareWhenTheOverlayRefusesTheFactor() {
        Settings.combinedBrightnessEnabled = false
        Settings.brightnessFloorBlendEnabled = true
        overlay.accepts = false

        XCTAssertTrue(module.set(0.05, on: display))

        XCTAssertEqual(apple.lastWrite, 0.05, accuracy: 1e-9,
                       "the request is written unchanged when nothing can dim it")
        XCTAssertEqual(display.floorBlendFactor, 1, accuracy: 1e-9,
                       "and no blend is reported")
        XCTAssertEqual(module.get(for: display) ?? -1, 0.05, accuracy: 1e-9,
                       "the read-back is what is on screen")
    }

    /// The other half of the same rule: above the threshold the blend stands
    /// aside and the hardware carries the request again — and the model
    /// follows the hardware once more.
    func testTheBlendIsReleasedWhenTheRequestLeavesTheThreshold() {
        Settings.combinedBrightnessEnabled = false
        Settings.brightnessFloorBlendEnabled = true

        XCTAssertTrue(module.set(0.05, on: display))
        XCTAssertEqual(display.floorBlendFactor, 0.05 / 0.15, accuracy: 1e-9)

        XCTAssertTrue(module.set(0.5, on: display))

        XCTAssertEqual(display.floorBlendFactor, 1, accuracy: 1e-9,
                       "the blend is released above the threshold")
        XCTAssertEqual(module.get(for: display) ?? -1, 0.5, accuracy: 1e-9)
        display.updateBrightness(0.5)
        XCTAssertEqual(display.brightness ?? -1, 0.5, accuracy: 1e-9,
                       "and the model follows the hardware again")
    }

    // MARK: - The upscale claim (the live session decides)

    /// A live boost session claims the upscale — that is what puts the
    /// brightness on screen.
    func testALiveBoostSessionClaimsTheUpscale() {
        Settings.combinedBrightnessEnabled = false
        xdr.available = false

        XCTAssertTrue(module.setTarget(800, on: display))

        XCTAssertTrue(display.isXDRUpscaled, "a live session claims the upscale")
        XCTAssertEqual(display.xdrUpscaleTargetNits, 800)
        XCTAssertTrue(display.isSoftwareUpscaled, "and the claim says which mechanism made it")
    }

    /// The claim has to go with its session. The session is what puts the
    /// brightness on screen, and it dies with the process that owned it (a
    /// one-shot CLI run) or when the capture fails — a claim that outlives
    /// it claims an upscale that is not on screen.
    func testTheClaimGoesWhenTheBoostSessionEnds() {
        Settings.combinedBrightnessEnabled = false
        xdr.available = false

        XCTAssertTrue(module.setTarget(800, on: display))
        XCTAssertTrue(display.isXDRUpscaled)

        // The session ends.
        overlay.activeSessions = []
        overlay.onSessionEnded?(display.id)

        XCTAssertFalse(display.isXDRUpscaled, "a claim without a session is a claim about nothing")
        XCTAssertNil(display.xdrUpscaleTargetNits)
        XCTAssertFalse(display.isSoftwareUpscaled)
    }

    /// The read-back has to follow the live state, not the stale flag: a
    /// claim that outlived its session would report a brightness the screen
    /// is not showing.
    func testTheReadBackFollowsTheLiveStateNotTheStaleFlag() {
        Settings.combinedBrightnessEnabled = true
        xdr.available = false
        apple.read = 0.4

        XCTAssertTrue(module.setTarget(800, on: display))
        // The session is live: the read-back is the upscale target.
        XCTAssertEqual(module.get(for: display) ?? -1, 800.0 / 1600.0, accuracy: 1e-9)

        // The session is gone but the claim is still there (no refresh has
        // run yet): the read-back must be the hardware brightness.
        overlay.activeSessions = []
        XCTAssertEqual(module.get(for: display) ?? -1, 0.4, accuracy: 1e-9,
                       "a stale claim must not decide the read-back")
    }

    /// A live session is never cleared: the claim stays as long as the
    /// boost is on screen.
    func testALiveSessionIsNeverCleared() {
        Settings.combinedBrightnessEnabled = false
        xdr.available = false

        XCTAssertTrue(module.setTarget(800, on: display))
        XCTAssertTrue(display.isXDRUpscaled)

        // Something else ends (a filter being stopped, for instance) — the
        // session is still live, so the claim stands.
        overlay.onSessionEnded?(display.id)

        XCTAssertTrue(display.isXDRUpscaled, "the claim follows the live session")
    }

    /// The native controller re-asserts the upscale state on every refresh,
    /// so it has to ask the overlay — not the model's own flag, which is
    /// what the boost wrote and can therefore never clear itself.
    func testTheNativeControllerIsWiredToTheLiveSessions() {
        overlay.activeSessions = [display.id]

        XCTAssertEqual(xdr.softwareBoostProvider(), [display.id],
                       "the native controller asks the overlay, not the model")
    }

    /// Releasing the boost ends the session — and the claim has to go with
    /// it.
    func testReleasingTheBoostClearsTheClaim() {
        Settings.combinedBrightnessEnabled = false
        xdr.available = false

        XCTAssertTrue(module.setTarget(800, on: display))
        XCTAssertTrue(display.isXDRUpscaled)

        // The boost is released — the route moved back to the hardware.
        overlay.setSoftwareBoost(1, displayID: display.id)

        XCTAssertFalse(display.isXDRUpscaled, "the claim follows its session")
    }

    /// The native preset path owns its own claim: a software session ending
    /// must not clear it — the preset is on screen as long as it is active.
    func testTheNativeClaimSurvivesASessionEnd() {
        Settings.combinedBrightnessEnabled = true
        xdr.available = true

        XCTAssertTrue(module.set(0.5, on: display))
        XCTAssertTrue(display.isXDRUpscaled, "the native preset claims the upscale")

        overlay.onSessionEnded?(display.id)

        XCTAssertTrue(display.isXDRUpscaled, "the preset is still on screen")
    }
}
