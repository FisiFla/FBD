import XCTest
import FBDCore

/// The below-floor brightness blend (issue #29).
///
/// The model is pure, so every property the issue asks for — monotonicity,
/// continuity at the handoff, an honest read-back — is checked here without a
/// display, an overlay or a settings store.
final class BrightnessFloorBlendTests: XCTestCase {
    private let blend = BrightnessFloorBlend(threshold: 0.15, isEnabled: true)

    // MARK: - The mapping

    func testBlendOffLeavesTheHardwareAlone() {
        let off = BrightnessFloorBlend(threshold: 0.15, isEnabled: false)

        let output = off.evaluate(0.05)

        XCTAssertEqual(output.hardware, 0.05)
        XCTAssertEqual(output.factor, 1)
    }

    func testAboveTheThresholdTheHardwareCarriesTheRequest() {
        let output = blend.evaluate(0.5)

        XCTAssertEqual(output.hardware, 0.5)
        XCTAssertEqual(output.factor, 1)
    }

    func testBelowTheThresholdTheHardwareIsPinnedAndTheSoftwareDims() {
        let output = blend.evaluate(0.05)

        XCTAssertEqual(output.hardware ?? -1, 0.15, accuracy: 0.0001,
                       "the hardware must sit at the threshold, not at the request")
        XCTAssertEqual(output.factor, 0.05 / 0.15, accuracy: 0.0001)
    }

    func testBottomOfTheSliderIsExactlyZero() {
        let output = blend.evaluate(0)

        XCTAssertEqual(output.factor, 0, "the software layer must reach zero")
        XCTAssertEqual(output.hardware ?? -1, 0.15, accuracy: 0.0001)
    }

    func testZeroThresholdDisablesTheBlend() {
        let noBand = BrightnessFloorBlend(threshold: 0, isEnabled: true)

        let output = noBand.evaluate(0.05)

        XCTAssertEqual(output.hardware, 0.05)
        XCTAssertEqual(output.factor, 1)
    }

    func testThresholdIsRaisedToTheMeasuredFloor() {
        let floored = BrightnessFloorBlend(threshold: 0.15, isEnabled: true, hardwareFloor: 0.4)

        XCTAssertEqual(floored.effectiveThreshold, 0.4, accuracy: 0.0001,
                       "blending above the panel's own floor would leave a step")
        let output = floored.evaluate(0.2)
        XCTAssertEqual(output.hardware ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(output.factor, 0.5, accuracy: 0.0001)
    }

    // MARK: - Continuity and monotonicity

    func testEffectiveBrightnessMatchesTheSliderAcrossTheWholeRange() {
        for step in 0...100 {
            let value = Double(step) / 100
            let output = blend.evaluate(value)
            let hardware = output.hardware ?? value
            let effective = hardware * output.factor

            XCTAssertEqual(effective, value, accuracy: 0.0001,
                           "the product of both layers must be the slider value at \(value)")
        }
    }

    func testCurveIsMonotonicAcrossTheBoundary() {
        var previous = -1.0
        for step in 0...100 {
            let value = Double(step) / 100
            let output = blend.evaluate(value)
            let effective = (output.hardware ?? value) * output.factor

            XCTAssertGreaterThanOrEqual(effective, previous - 0.0001,
                                        "the curve must not go backwards at \(value)")
            previous = effective
        }
    }

    func testNoDiscontinuityAtTheThreshold() {
        let below = blend.evaluate(0.1499)
        let above = blend.evaluate(0.1501)

        let belowEffective = (below.hardware ?? 0) * below.factor
        let aboveEffective = (above.hardware ?? 0) * above.factor

        XCTAssertEqual(belowEffective, aboveEffective, accuracy: 0.001,
                       "dragging through the threshold must not produce a band")
    }

    func testEvaluateAndReconstructionAgree() {
        for step in 0...100 {
            let value = Double(step) / 100
            let output = blend.evaluate(value)
            let reconstructed = blend.reconstructSlider(
                hardwareReadBack: output.hardware,
                softwareFactor: output.factor
            )

            XCTAssertEqual(reconstructed, value, accuracy: 0.0001,
                           "the read-back must report the logical position at \(value)")
        }
    }

    // MARK: - Honest read-back

    func testReadBackReportsTheLogicalPositionNotTheFloor() {
        // The user asked for 0 %, the hardware is pinned at the threshold.
        let output = blend.evaluate(0)
        let reconstructed = blend.reconstructSlider(
            hardwareReadBack: output.hardware,
            softwareFactor: output.factor
        )

        XCTAssertEqual(reconstructed, 0, accuracy: 0.0001,
                       "0 % must not read back as the panel's floor")
    }

    func testReadBackUsesTheHardwareWhenTheBlendIsNotInForce() {
        let reconstructed = blend.reconstructSlider(hardwareReadBack: 0.42, softwareFactor: 1)

        XCTAssertEqual(reconstructed, 0.42, accuracy: 0.0001)
    }

    func testReadBackUsesTheHardwareWhenItMovedOn() {
        // The monitor changed the brightness through its own OSD: the
        // hardware read is the truth, not our factor.
        let reconstructed = blend.reconstructSlider(hardwareReadBack: 0.4, softwareFactor: 0.2)

        XCTAssertEqual(reconstructed, 0.4, accuracy: 0.0001)
    }

    func testReadBackWithBlendOffIsTheHardwareRead() {
        let off = BrightnessFloorBlend(threshold: 0.15, isEnabled: false)

        let reconstructed = off.reconstructSlider(hardwareReadBack: 0.3, softwareFactor: 0.1)

        XCTAssertEqual(reconstructed, 0.3, accuracy: 0.0001)
    }

    func testMissingHardwareReadIsZero() {
        let reconstructed = blend.reconstructSlider(hardwareReadBack: nil, softwareFactor: 0.5)

        XCTAssertEqual(reconstructed, 0)
    }

    // MARK: - HDR

    func testHDRRoutesTheWholeRangeToTheSoftwareLayer() {
        let output = blend.evaluate(0.8, hdrActive: true)

        XCTAssertNil(output.hardware, "the DDC scale does not describe the panel in HDR")
        XCTAssertEqual(output.factor, 0.8, accuracy: 0.0001)
    }

    func testHDRWithTheBlendOffKeepsTheHardwareWrite() {
        let off = BrightnessFloorBlend(threshold: 0.15, isEnabled: false)

        let output = off.evaluate(0.8, hdrActive: true)

        XCTAssertEqual(output.hardware, 0.8)
        XCTAssertEqual(output.factor, 1)
    }

    func testHDRReadBackIsTheSoftwareFactor() {
        let reconstructed = blend.reconstructSlider(
            hardwareReadBack: 0.15,
            softwareFactor: 0.42,
            hdrActive: true
        )

        XCTAssertEqual(reconstructed, 0.42, accuracy: 0.0001)
    }
}
