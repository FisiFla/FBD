import XCTest
@testable import FBDCore

final class XDRPresetTests: XCTestCase {
    // MARK: - clampedTarget

    func testClampedTargetRaisesBelowMinSliderBrightness() {
        // Arrange
        let preset = makePreset() // min slider 4, HDR max 1600

        // Act / Assert
        XCTAssertEqual(XDRNativeController.clampedTarget(0, preset: preset), 4)
        XCTAssertEqual(XDRNativeController.clampedTarget(-10, preset: preset), 4)
    }

    func testClampedTargetCapsAboveMaxHDRLuminance() {
        // Arrange
        let preset = makePreset()

        // Act / Assert
        XCTAssertEqual(XDRNativeController.clampedTarget(5000, preset: preset), 1600)
        XCTAssertEqual(XDRNativeController.clampedTarget(2000, preset: preset), 1600)
    }

    func testClampedTargetPassesThroughInRange() {
        // Arrange
        let preset = makePreset()

        // Act / Assert
        XCTAssertEqual(XDRNativeController.clampedTarget(300, preset: preset), 300)
        XCTAssertEqual(XDRNativeController.clampedTarget(1600, preset: preset), 1600)
        XCTAssertEqual(XDRNativeController.clampedTarget(4, preset: preset), 4)
    }

    // MARK: - isFBDSlotName

    func testIsFBDSlotNameTrueForFBDPreset() {
        XCTAssertTrue(XDRNativeController.isFBDSlotName("FBD XDR (1600 nits)"))
        XCTAssertTrue(XDRNativeController.isFBDSlotName("FBD XDR (300 nits)"))
    }

    func testIsFBDSlotNameFalseForFactoryAndEmptyNames() {
        XCTAssertFalse(XDRNativeController.isFBDSlotName("Apple XDR Display (P3-1600 nits)"))
        XCTAssertFalse(XDRNativeController.isFBDSlotName(""))
        XCTAssertFalse(XDRNativeController.isFBDSlotName("FBD"))
    }

    // MARK: - upscaleNits(fromPresetName:)

    func testUpscaleNitsParsesTargetFromFBDName() {
        XCTAssertEqual(XDRNativeController.upscaleNits(fromPresetName: "FBD XDR (1600 nits)"), 1600)
        XCTAssertEqual(XDRNativeController.upscaleNits(fromPresetName: "FBD XDR (300 nits)"), 300)
    }

    func testUpscaleNitsReturnsNilForGarbage() {
        XCTAssertNil(XDRNativeController.upscaleNits(fromPresetName: "Apple XDR Display (P3-1600 nits)"))
        XCTAssertNil(XDRNativeController.upscaleNits(fromPresetName: "FBD XDR (lots of nits)"))
        XCTAssertNil(XDRNativeController.upscaleNits(fromPresetName: "FBD XDR"))
        XCTAssertNil(XDRNativeController.upscaleNits(fromPresetName: ""))
    }

    // MARK: - upscaledPresetData (SkyLightAPI pure transform)

    func testUpscaledPresetDataRaisesSDRAndSliderToTarget() {
        // Arrange
        let base = baseDict()

        // Act
        let upscaled = SkyLightAPI.upscaledPresetData(from: base, targetNits: 1600)

        // Assert
        XCTAssertEqual(upscaled["PresetMaxSDRLuminance"] as? Int, 1600)
        XCTAssertEqual(upscaled["PresetHostMaxSliderBrightness"] as? Int, 1600)
        XCTAssertEqual(upscaled["PresetMaxHDRLuminance"] as? Int, 1600)
        XCTAssertEqual(upscaled["PresetName"] as? String, "FBD XDR (1600 nits)")
        XCTAssertEqual(upscaled["PresetValid"] as? Int, 1)
        XCTAssertEqual(upscaled["PresetWhitePoint"] as? Int, 3, "unrelated keys must be preserved")
    }

    func testUpscaledPresetDataLiftsHDRMaxAboveTarget() {
        // Arrange
        let base = baseDict()

        // Act
        let upscaled = SkyLightAPI.upscaledPresetData(from: base, targetNits: 2000)

        // Assert
        XCTAssertEqual(upscaled["PresetMaxSDRLuminance"] as? Int, 2000)
        XCTAssertEqual(upscaled["PresetHostMaxSliderBrightness"] as? Int, 2000)
        XCTAssertEqual(upscaled["PresetMaxHDRLuminance"] as? Int, 2000)
    }

    func testUpscaledPresetDataBelowSDRRaisesSDRAndSliderButKeepsHDRMax() {
        // Arrange
        let base = baseDict()

        // Act
        let upscaled = SkyLightAPI.upscaledPresetData(from: base, targetNits: 300)

        // Assert: SDR + slider follow the target; the HDR maximum never drops
        // below the base preset's HDR maximum (max(1600, 300) == 1600).
        XCTAssertEqual(upscaled["PresetMaxSDRLuminance"] as? Int, 300)
        XCTAssertEqual(upscaled["PresetHostMaxSliderBrightness"] as? Int, 300)
        XCTAssertEqual(upscaled["PresetMaxHDRLuminance"] as? Int, 1600)
    }

    // MARK: - Helpers

    /// A realistic built-in XDR factory preset (P3-1600).
    private func makePreset(
        index: Int = 0,
        name: String = "Apple XDR Display (P3-1600 nits)",
        maxSDR: Int = 500,
        maxHDR: Int = 1600,
        maxSlider: Int = 500,
        minSlider: Int = 4
    ) -> XDRPreset {
        XDRPreset(
            index: index,
            name: name,
            isValid: true,
            isWritable: false,
            maxSDRLuminance: maxSDR,
            maxHDRLuminance: maxHDR,
            maxSliderBrightness: maxSlider,
            minSliderBrightness: minSlider,
            edrHeadroom: 16,
            uniqueID: nil,
            raw: [:]
        )
    }

    private func baseDict() -> [String: Any] {
        [
            "PresetMaxSDRLuminance": 500,
            "PresetMaxHDRLuminance": 1600,
            "PresetHostMaxSliderBrightness": 500,
            "PresetName": "Apple XDR Display (P3-1600 nits)",
            "PresetValid": 1,
            "PresetWhitePoint": 3,
        ]
    }
}
