import XCTest
@testable import FBDCore

/// `ScreenFilterParams` domain clamping and neutrality.
///
/// The clamping lives in the initialiser precisely so that no caller — CLI,
/// HTTP, UI or App Intent — can push the Metal uniform block outside the range
/// the shader is written against. `isNeutral` decides whether the overlay is
/// torn down, so its edges are asserted explicitly.
final class ScreenFilterParamsTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultsAreNeutral() {
        XCTAssertTrue(ScreenFilterParams.neutral.isNeutral)
        XCTAssertTrue(ScreenFilterParams().isNeutral)
    }

    func testNeutralDefaultsForNewFields() {
        let params = ScreenFilterParams()
        XCTAssertEqual(params.sharpness, 0)
        XCTAssertEqual(params.unsharpRadius, 1)
        XCTAssertEqual(params.zoom, 1)
        XCTAssertEqual(params.offsetX, 0)
        XCTAssertEqual(params.offsetY, 0)
        XCTAssertNil(params.lutPath)
    }

    // MARK: - Sharpness

    func testSharpnessIsClampedToMax() {
        XCTAssertEqual(ScreenFilterParams(sharpness: 999).sharpness, ScreenFilterParams.maxSharpness)
        XCTAssertEqual(ScreenFilterParams(sharpness: -5).sharpness, 0)
    }

    func testUnsharpRadiusIsClamped() {
        XCTAssertEqual(ScreenFilterParams(unsharpRadius: 1000).unsharpRadius, ScreenFilterParams.maxUnsharpRadius)
        XCTAssertEqual(ScreenFilterParams(unsharpRadius: -1).unsharpRadius, 0)
    }

    func testSharpnessBreaksNeutrality() {
        XCTAssertFalse(ScreenFilterParams(sharpness: 1).isNeutral)
    }

    func testNonDefaultRadiusAloneStaysNeutral() {
        // The radius is only meaningful when sharpness > 0, so on its own it
        // must not hold a capture session open.
        XCTAssertTrue(ScreenFilterParams(unsharpRadius: 5).isNeutral)
    }

    // MARK: - Geometry

    func testZoomIsClampedToOneOrMore() {
        XCTAssertEqual(ScreenFilterParams(zoom: 0.5).zoom, 1)
        XCTAssertEqual(ScreenFilterParams(zoom: -3).zoom, 1)
        XCTAssertEqual(ScreenFilterParams(zoom: 100).zoom, ScreenFilterParams.maxZoom)
    }

    func testOffsetIsClampedIntoTheZoomedViewport() {
        // With zoom 2 the viewport may only travel 0.25 either way.
        let params = ScreenFilterParams(zoom: 2, offsetX: 5, offsetY: -5)
        XCTAssertEqual(params.offsetX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(params.offsetY, -0.25, accuracy: 1e-9)
    }

    func testOffsetIsZeroWhenNotZoomed() {
        // At zoom 1 there is no margin: any pan would sample outside the source.
        let params = ScreenFilterParams(zoom: 1, offsetX: 0.4, offsetY: 0.4)
        XCTAssertEqual(params.offsetX, 0)
        XCTAssertEqual(params.offsetY, 0)
        XCTAssertTrue(params.isNeutral)
    }

    func testOffsetWithinMarginIsPreserved() {
        let params = ScreenFilterParams(zoom: 4, offsetX: 0.1, offsetY: -0.2)
        XCTAssertEqual(params.offsetX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(params.offsetY, -0.2, accuracy: 1e-9)
    }

    func testGeometryBreaksNeutrality() {
        XCTAssertFalse(ScreenFilterParams(zoom: 2).isNeutral)
        XCTAssertFalse(ScreenFilterParams(zoom: 2, offsetX: 0.1).isNeutral)
    }

    // MARK: - LUT

    func testLUTPathBreaksNeutrality() {
        XCTAssertFalse(ScreenFilterParams(lutPath: "/tmp/x.cube").isNeutral)
    }

    func testLUTPathParticipatesInEquality() {
        XCTAssertNotEqual(ScreenFilterParams(lutPath: "/tmp/a.cube"), ScreenFilterParams(lutPath: "/tmp/b.cube"))
        XCTAssertEqual(ScreenFilterParams(lutPath: "/tmp/a.cube"), ScreenFilterParams(lutPath: "/tmp/a.cube"))
    }

    // MARK: - Existing behaviour preserved

    func testBoostBrightnessIsNotClamped() {
        // The XDR software boost is just brightness > 1 — it must survive.
        XCTAssertEqual(ScreenFilterParams(brightness: 2.5).brightness, 2.5)
        XCTAssertFalse(ScreenFilterParams(brightness: 2.5).isNeutral)
    }
}
