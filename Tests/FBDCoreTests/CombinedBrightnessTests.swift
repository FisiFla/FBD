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

    func isAvailable(for display: Display) -> Bool { available }

    @discardableResult
    func setUpscaleTarget(_ nits: Int, for display: Display) -> Bool {
        writeCalls += 1
        lastTarget = nits
        let ok = writeOutcomes.isEmpty ? true : writeOutcomes[min(writeCalls - 1, writeOutcomes.count - 1)]
        if ok {
            currentTarget = nits
            display.updateSoftwareBoost(true, targetNits: nits)
        }
        return ok
    }

    @discardableResult
    func disableUpscaling(for display: Display) -> Bool {
        disableCalls += 1
        currentTarget = nil
        display.updateSoftwareBoost(false, targetNits: nil)
        return true
    }

    func upscaleTarget(for display: Display) -> Int? { currentTarget }
}

@MainActor
private final class FakeOverlay: OverlayControlling {
    var accepts = true
    var boostCalls: [(factor: Double, displayID: CGDirectDisplayID)] = []

    @discardableResult
    func setSoftwareBoost(_ factor: Double, displayID: CGDirectDisplayID) -> Bool {
        boostCalls.append((factor, displayID))
        return accepts
    }
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

    override func setUp() {
        super.setUp()
        savedCombined = Settings.combinedBrightnessEnabled
        savedSoftware = Settings.softwareUpscalingEnabled
        savedTarget = Settings.xdrUpscaleTargetNits
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
    }

    override func tearDown() {
        // Restore the real values — writes through @Storage hit the live
        // defaults suite, so a hardcoded tearDown would pollute the app.
        Settings.combinedBrightnessEnabled = savedCombined
        Settings.softwareUpscalingEnabled = savedSoftware
        Settings.xdrUpscaleTargetNits = savedTarget
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
}
