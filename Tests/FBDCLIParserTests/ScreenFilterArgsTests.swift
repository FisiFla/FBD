import XCTest
@testable import FBDCLIParser

/// `ScreenFilterArgs` — the shared parser behind `fbdcli filter` and the routed
/// HTTP plan. The four positional values keep their historical shape; the
/// sharpening/geometry/LUT flags are additive.
final class ScreenFilterArgsTests: XCTestCase {

    private func parse(_ args: [String]) throws -> ScreenFilterArgs {
        switch ScreenFilterArgs.parse(args) {
        case .success(let parsed): return parsed
        case .failure(let failure): throw failure
        }
    }

    // MARK: - Positional values

    func testParsesFourPositionalValues() throws {
        let parsed = try parse(["1.2", "0.9", "1.4", "1.1"])
        XCTAssertEqual(parsed.contrast, 1.2, accuracy: 1e-9)
        XCTAssertEqual(parsed.saturation, 0.9, accuracy: 1e-9)
        XCTAssertEqual(parsed.gamma, 1.4, accuracy: 1e-9)
        XCTAssertEqual(parsed.temperature, 1.1, accuracy: 1e-9)
        XCTAssertFalse(parsed.invert)
        XCTAssertNil(parsed.sharpness)
        XCTAssertNil(parsed.zoom)
        XCTAssertNil(parsed.lutPath)
    }

    func testRejectsTooFewArguments() {
        guard case .failure = ScreenFilterArgs.parse(["1", "1", "1"]) else {
            return XCTFail("expected failure for a missing positional value")
        }
        guard case .failure = ScreenFilterArgs.parse([]) else {
            return XCTFail("expected failure for no arguments")
        }
    }

    func testRejectsNonNumericPositionalValue() {
        guard case .failure = ScreenFilterArgs.parse(["1", "1", "1", "warm"]) else {
            return XCTFail("expected failure for a non-numeric value")
        }
    }

    func testRejectsNegativePositionalValue() {
        guard case .failure = ScreenFilterArgs.parse(["-1", "1", "1", "1"]) else {
            return XCTFail("expected failure for a negative value")
        }
    }

    // MARK: - Sharpening

    func testParsesSharpnessAndRadius() throws {
        let parsed = try parse(["1", "1", "1", "1", "--sharpness", "3.5", "--radius", "2"])
        XCTAssertEqual(parsed.sharpness, 3.5)
        XCTAssertEqual(parsed.unsharpRadius, 2)
    }

    func testRejectsMissingSharpnessValue() {
        guard case .failure = ScreenFilterArgs.parse(["1", "1", "1", "1", "--sharpness"]) else {
            return XCTFail("expected failure for a flag with no value")
        }
    }

    // MARK: - Geometry

    func testParsesZoom() throws {
        XCTAssertEqual(try parse(["1", "1", "1", "1", "--zoom", "2.5"]).zoom, 2.5)
    }

    func testRejectsZoomBelowOne() {
        // Zooming out would expose the clamp-to-edge sampler.
        guard case .failure = ScreenFilterArgs.parse(["1", "1", "1", "1", "--zoom", "0.5"]) else {
            return XCTFail("expected failure for zoom < 1")
        }
    }

    func testParsesPanPair() throws {
        let parsed = try parse(["1", "1", "1", "1", "--zoom", "2", "--pan", "0.1", "-0.2"])
        XCTAssertEqual(parsed.offsetX, 0.1)
        XCTAssertEqual(parsed.offsetY, -0.2)
    }

    func testRejectsIncompletePanPair() {
        guard case .failure = ScreenFilterArgs.parse(["1", "1", "1", "1", "--pan", "0.1"]) else {
            return XCTFail("expected failure for a half-specified pan")
        }
    }

    // MARK: - LUT

    func testParsesLUTPath() throws {
        XCTAssertEqual(try parse(["1", "1", "1", "1", "--lut", "/tmp/grade.cube"]).lutPath, "/tmp/grade.cube")
    }

    func testRejectsEmptyLUTPath() {
        guard case .failure = ScreenFilterArgs.parse(["1", "1", "1", "1", "--lut", ""]) else {
            return XCTFail("expected failure for an empty LUT path")
        }
    }

    // MARK: - Flag handling

    func testParsesCombinedFlags() throws {
        let parsed = try parse(["1.1", "1", "1", "1", "--invert", "--sharpness", "4", "--zoom", "2", "--lut", "/tmp/x.cube"])
        XCTAssertTrue(parsed.invert)
        XCTAssertEqual(parsed.sharpness, 4)
        XCTAssertEqual(parsed.zoom, 2)
        XCTAssertEqual(parsed.lutPath, "/tmp/x.cube")
    }

    func testRejectsUnknownFlag() {
        guard case .failure = ScreenFilterArgs.parse(["1", "1", "1", "1", "--saturation", "2"]) else {
            return XCTFail("expected failure for an unknown flag")
        }
    }

    // MARK: - Payload

    func testPayloadCarriesOnlySuppliedOptionalFields() throws {
        let payload = try parse(["1", "0.5", "1", "1"]).payload
        XCTAssertNotNil(payload["contrast"])
        XCTAssertNotNil(payload["saturation"])
        XCTAssertNotNil(payload["gamma"])
        XCTAssertNotNil(payload["temperature"])
        // Not supplied → must be absent, so the receiver's defaults win rather
        // than a stale value being written back.
        for key in ["invert", "sharpness", "unsharpRadius", "zoom", "offsetX", "offsetY", "lutPath"] {
            XCTAssertNil(payload[key], "\(key) should be absent when not supplied")
        }
    }

    func testPayloadCarriesEverySuppliedField() throws {
        let args = ["1", "1", "1", "1", "--invert", "--sharpness", "2", "--radius", "3",
                    "--zoom", "2", "--pan", "0.1", "0.2", "--lut", "/tmp/x.cube"]
        let payload = try parse(args).payload
        XCTAssertEqual(payload["invert"] as? Bool, true)
        XCTAssertEqual(payload["sharpness"] as? Double, 2)
        XCTAssertEqual(payload["unsharpRadius"] as? Double, 3)
        XCTAssertEqual(payload["zoom"] as? Double, 2)
        XCTAssertEqual(payload["offsetX"] as? Double, 0.1)
        XCTAssertEqual(payload["offsetY"] as? Double, 0.2)
        XCTAssertEqual(payload["lutPath"] as? String, "/tmp/x.cube")
    }
}
