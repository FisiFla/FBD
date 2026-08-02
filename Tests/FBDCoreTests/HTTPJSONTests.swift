import XCTest
import FBDCore

/// Tests for the HTTP JSON helpers: display serialization, mode matching
/// and id parsing (pure logic used by the app's HTTP API).
final class HTTPJSONTests: XCTestCase {
    private func makeDisplay(
        id: CGDirectDisplayID = 1,
        brightness: Double? = nil,
        modes: [DisplayMode] = [],
        currentMode: DisplayMode? = nil
    ) -> Display {
        let display = Display(
            id: id,
            name: "Test Display",
            isBuiltin: false,
            vendorNumber: 0x1234,
            modelNumber: 0x5678,
            serialNumber: 0x11223344,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            isOnline: true,
            isActive: true
        )
        display.updateModes(modes, current: currentMode)
        if let brightness {
            display.updateBrightness(brightness)
        }
        return display
    }

    private func mode(_ number: Int32, w: Int32, h: Int32, hz: Double, hidpi: Bool, safe: Bool = true) -> DisplayMode {
        DisplayMode(
            modeNumber: number,
            flags: (hidpi ? DisplayMode.hiDPIFlag : 0) | (safe ? DisplayMode.safeFlag : 0),
            width: w, height: h,
            pixelsWide: w, pixelsHigh: h,
            refreshRate: hz,
            encoding: "test"
        )
    }

    // MARK: - parseDisplayID

    func testParseDisplayIDDecimalAndHex() {
        XCTAssertEqual(HTTPJSON.parseDisplayID("7"), 7)
        XCTAssertEqual(HTTPJSON.parseDisplayID("0x10"), 16)
        XCTAssertEqual(HTTPJSON.parseDisplayID("0X1F"), 31)
        XCTAssertNil(HTTPJSON.parseDisplayID("abc"))
        XCTAssertNil(HTTPJSON.parseDisplayID(""))
    }

    // MARK: - display serialization

    func testDisplayJSONContainsCoreKeys() throws {
        let json = HTTPJSON.display(makeDisplay(id: 42, brightness: 0.5))
        XCTAssertEqual(json["id"] as? CGDirectDisplayID, 42)
        XCTAssertEqual(json["name"] as? String, "Test Display")
        XCTAssertEqual(json["builtin"] as? Bool, false)
        XCTAssertEqual(json["virtual"] as? Bool, false)
        XCTAssertEqual(json["brightness"] as? Double, 0.5)
        XCTAssertEqual(json["xdrCapable"] as? Bool, false)
        XCTAssertEqual(json["xdrUpscaled"] as? Bool, false)
        let bounds = try XCTUnwrap(json["bounds"] as? [String: Any])
        XCTAssertEqual((bounds["width"] as? NSNumber)?.doubleValue, 1920)
        XCTAssertEqual((bounds["height"] as? NSNumber)?.doubleValue, 1080)
    }

    func testDisplayJSONOmitsNilBrightnessAndMode() {
        let json = HTTPJSON.display(makeDisplay())
        XCTAssertNil(json["brightness"])
        XCTAssertNil(json["currentMode"])
    }

    func testModeJSONShape() {
        let json = HTTPJSON.mode(mode(3, w: 1920, h: 1080, hz: 60, hidpi: true))
        XCTAssertEqual(json["key"] as? String, "1920x1080@60.00")
        XCTAssertEqual(json["width"] as? Int32, 1920)
        XCTAssertEqual(json["hz"] as? Double, 60)
        XCTAssertEqual(json["hidpi"] as? Bool, true)
        XCTAssertEqual(json["safe"] as? Bool, true)
    }

    // MARK: - bestMode

    func testBestModePrefersExactRefreshRate() {
        let display = makeDisplay(modes: [
            mode(1, w: 1920, h: 1080, hz: 60, hidpi: false),
            mode(2, w: 1920, h: 1080, hz: 120, hidpi: false),
            mode(3, w: 1920, h: 1080, hz: 59.94, hidpi: false),
        ])
        XCTAssertEqual(HTTPJSON.bestMode(matchingWidth: 1920, height: 1080, hz: 120, in: display)?.modeNumber, 2)
        XCTAssertEqual(HTTPJSON.bestMode(matchingWidth: 1920, height: 1080, hz: 60, in: display)?.modeNumber, 1)
    }

    func testBestModePicksNearestRefreshRate() {
        let display = makeDisplay(modes: [
            mode(1, w: 1920, h: 1080, hz: 60, hidpi: false),
            mode(2, w: 1920, h: 1080, hz: 144, hidpi: false),
        ])
        // 120 is closer to 144 than to 60.
        XCTAssertEqual(HTTPJSON.bestMode(matchingWidth: 1920, height: 1080, hz: 120, in: display)?.modeNumber, 2)
    }

    func testBestModePrefersHiDPIOnTie() {
        let display = makeDisplay(modes: [
            mode(1, w: 1920, h: 1080, hz: 60, hidpi: false),
            mode(2, w: 1920, h: 1080, hz: 60, hidpi: true),
        ])
        XCTAssertEqual(HTTPJSON.bestMode(matchingWidth: 1920, height: 1080, hz: 60, in: display)?.modeNumber, 2)
    }

    func testBestModeWithoutHzKeepsCurrentRefreshRate() {
        let current = mode(9, w: 1920, h: 1080, hz: 100, hidpi: true)
        let display = makeDisplay(modes: [
            mode(1, w: 1920, h: 1080, hz: 60, hidpi: true),
            mode(2, w: 1920, h: 1080, hz: 100, hidpi: true),
        ], currentMode: current)
        XCTAssertEqual(HTTPJSON.bestMode(matchingWidth: 1920, height: 1080, hz: nil, in: display)?.modeNumber, 2)
    }

    func testBestModeWithoutHzFallsBackToHiDPIThenFastest() {
        let display = makeDisplay(modes: [
            mode(1, w: 1920, h: 1080, hz: 60, hidpi: true),
            mode(2, w: 1920, h: 1080, hz: 144, hidpi: false),
        ])
        // No current mode: HiDPI wins over raw speed.
        XCTAssertEqual(HTTPJSON.bestMode(matchingWidth: 1920, height: 1080, hz: nil, in: display)?.modeNumber, 1)
    }

    func testBestModeNoMatchReturnsNil() {
        let display = makeDisplay(modes: [mode(1, w: 1280, h: 720, hz: 60, hidpi: false)])
        XCTAssertNil(HTTPJSON.bestMode(matchingWidth: 1920, height: 1080, hz: nil, in: display))
    }

    // MARK: - encode/parse round-trip

    func testEncodeParseRoundTrip() {
        let object: [String: Any] = ["ok": true, "n": 42, "s": "x"]
        let json = HTTPJSON.encode(object)
        XCTAssertEqual(HTTPJSON.parse(json)?["n"] as? Int, 42)
        XCTAssertEqual(HTTPJSON.error("boom"), #"{"error":"boom"}"#)
    }
}
