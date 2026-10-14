import CoreGraphics
import XCTest
@testable import FBDCore

/// Pure selection logic for per-property configuration protection: name
/// parsing, the apply-order listing, and which properties a given display
/// exposes. No hardware involved.
final class ProtectedPropertiesTests: XCTestCase {

    private func makeDisplay(
        id: CGDirectDisplayID = 1,
        vendor: UInt32 = 0x10AC,
        model: UInt32 = 0x1234
    ) -> Display {
        Display(
            id: id,
            name: "Protection Test",
            isBuiltin: false,
            vendorNumber: vendor,
            modelNumber: model,
            serialNumber: 0x5678,
            bounds: .zero,
            isOnline: true,
            isActive: true
        )
    }

    private func makeMode(number: Int32 = 7, refreshRate: Double = 60) -> DisplayMode {
        DisplayMode(
            modeNumber: number,
            flags: DisplayMode.safeFlag,
            width: 1920,
            height: 1080,
            pixelsWide: 1920,
            pixelsHigh: 1080,
            refreshRate: refreshRate,
            encoding: "RGB "
        )
    }

    private func makePreset(index: Int = 0) -> XDRPreset {
        XDRPreset(
            index: index,
            name: "Test Preset \(index)",
            isValid: true,
            isWritable: true,
            maxSDRLuminance: 500,
            maxHDRLuminance: 1600,
            maxSliderBrightness: 1600,
            minSliderBrightness: 0,
            edrHeadroom: 16,
            uniqueID: Data(repeating: 0, count: 16),
            raw: [:]
        )
    }

    // MARK: - Set algebra

    func testAllContainsEveryNamedProperty() {
        for (name, property) in ProtectedProperties.ordered {
            XCTAssertTrue(ProtectedProperties.all.contains(property), "all must contain \(name)")
        }
        XCTAssertEqual(ProtectedProperties.all.names.count, ProtectedProperties.ordered.count)
    }

    func testLegacyDefaultIsModeBrightnessPreset() {
        XCTAssertEqual(ProtectedProperties.legacyDefault, [.resolution, .brightness, .preset])
        XCTAssertFalse(ProtectedProperties.legacyDefault.contains(.hdrMode))
        XCTAssertFalse(ProtectedProperties.legacyDefault.contains(.mainStatus))
        XCTAssertFalse(ProtectedProperties.legacyDefault.contains(.refreshRate))
    }

    func testNamesFollowApplyOrder() {
        // Apply order is resolution, refreshRate, preset, hdrMode, mainStatus, brightness.
        let set: ProtectedProperties = [.brightness, .mainStatus, .resolution]
        XCTAssertEqual(set.names, ["resolution", "mainStatus", "brightness"])
    }

    // MARK: - Parsing

    func testParseAcceptsCommaSeparatedNames() {
        XCTAssertEqual(ProtectedProperties.parse("resolution,brightness"), [.resolution, .brightness])
    }

    func testParseIsCaseInsensitiveAndToleratesSpaces() {
        XCTAssertEqual(ProtectedProperties.parse(" RefreshRate , HDRMode "), [.refreshRate, .hdrMode])
    }

    func testParseAllExpands() {
        XCTAssertEqual(ProtectedProperties.parse("all"), .all)
    }

    func testParseAccumulatesWithAll() {
        XCTAssertEqual(ProtectedProperties.parse("all,brightness"), .all)
    }

    /// A typo must be refused, not silently dropped — otherwise a user could
    /// believe a property is protected when it is not.
    func testParseRejectsUnknownName() {
        XCTAssertNil(ProtectedProperties.parse("resolution,nonsense"))
        XCTAssertNil(ProtectedProperties.parse(""))
        XCTAssertNil(ProtectedProperties.parse(" "))
    }

    func testNamesRoundTripThroughParse() {
        for property in [ProtectedProperties.all, .legacyDefault, [.hdrMode], [.mainStatus]] {
            XCTAssertEqual(
                ProtectedProperties.parse(property.names.joined(separator: ",")),
                property,
                "names/parse must round-trip for \(property.rawValue)"
            )
        }
    }

    // MARK: - Availability

    func testBareDisplayOnlyExposesMainStatus() {
        // A display with no mode, no brightness path and no XDR/HDR support.
        XCTAssertEqual(ProtectedProperties.available(for: makeDisplay()), [.mainStatus])
    }

    func testModeExposesResolutionAndRefreshRate() {
        let display = makeDisplay()
        let mode = makeMode()
        display.updateModes([mode], current: mode)
        let available = ProtectedProperties.available(for: display)
        XCTAssertTrue(available.contains(.resolution))
        XCTAssertTrue(available.contains(.refreshRate))
        XCTAssertFalse(available.contains(.brightness))
    }

    func testBrightnessExposedByAnyControlPath() {
        let apple = makeDisplay(id: 1)
        apple.updateAppleBrightnessStatus(available: true)
        XCTAssertTrue(ProtectedProperties.available(for: apple).contains(.brightness))

        let ddc = makeDisplay(id: 2)
        ddc.updateDDCStatus(available: true, capabilities: nil)
        XCTAssertTrue(ProtectedProperties.available(for: ddc).contains(.brightness))
    }

    func testPresetRequiresCapabilityAndPresets() {
        let display = makeDisplay()
        display.updateXDRState(
            presets: [],
            isXDRCapable: true,
            activePresetIndex: nil,
            isXDRUpscaled: false,
            xdrUpscaleTargetNits: nil,
            isHDRModeCapable: false,
            isHDRModeEnabled: false
        )
        XCTAssertFalse(
            ProtectedProperties.available(for: display).contains(.preset),
            "XDR-capable but with no presets listed must not offer preset protection"
        )

        display.updateXDRState(
            presets: [makePreset()],
            isXDRCapable: true,
            activePresetIndex: 0,
            isXDRUpscaled: false,
            xdrUpscaleTargetNits: nil,
            isHDRModeCapable: false,
            isHDRModeEnabled: false
        )
        XCTAssertTrue(ProtectedProperties.available(for: display).contains(.preset))
    }

    func testHDRModeRequiresCapability() {
        let display = makeDisplay()
        display.updateXDRState(
            presets: [],
            isXDRCapable: false,
            activePresetIndex: nil,
            isXDRUpscaled: false,
            xdrUpscaleTargetNits: nil,
            isHDRModeCapable: true,
            isHDRModeEnabled: true
        )
        XCTAssertTrue(ProtectedProperties.available(for: display).contains(.hdrMode))
    }
}
