import XCTest
@testable import FBDCore

/// `/api/system/...` routing — the Mac's own audio (#20).
///
/// Separate from `/api/displays` on purpose: this controls the Mac's output, not
/// a display's speakers, and those are different devices reached by different
/// mechanisms (CoreAudio HAL vs DDC).
final class HTTPSystemRouteTests: XCTestCase {
    private let token = "test-token"

    private func route(_ method: String, _ path: String, body: String? = nil) -> HTTPRouteResult {
        HTTPRouter.route(
            method: method,
            path: path,
            body: body,
            headers: ["x-fbd-token": token],
            expectedToken: token
        )
    }

    private func routed(_ result: HTTPRouteResult) -> HTTPRoute? {
        if case .route(let route) = result { return route }
        return nil
    }

    private func errorStatus(_ result: HTTPRouteResult) -> Int? {
        if case .error(let status, _) = result { return status }
        return nil
    }

    // MARK: - Reading

    func testReadSystemVolume() {
        XCTAssertEqual(
            routed(route("GET", "/api/system/volume")),
            HTTPRoute.systemVolume(device: nil, value: nil)
        )
    }

    func testAudioDeviceList() {
        XCTAssertEqual(routed(route("GET", "/api/system/audio-devices")), HTTPRoute.systemAudioDevices)
    }

    // MARK: - Writing

    func testWriteSystemVolume() {
        XCTAssertEqual(
            routed(route("POST", "/api/system/volume", body: #"{"value":0.4}"#)),
            HTTPRoute.systemVolume(device: nil, value: 0.4)
        )
    }

    func testWriteNamesAnExplicitDevice() {
        // An HDMI default output has no volume control; naming a device is how a
        // caller reaches one that does.
        XCTAssertEqual(
            routed(route("POST", "/api/system/volume", body: #"{"device":75,"value":0.4}"#)),
            HTTPRoute.systemVolume(device: 75, value: 0.4)
        )
    }

    func testZeroAndOneAreAccepted() {
        XCTAssertEqual(
            routed(route("POST", "/api/system/volume", body: #"{"value":0}"#)),
            HTTPRoute.systemVolume(device: nil, value: 0)
        )
        XCTAssertEqual(
            routed(route("POST", "/api/system/volume", body: #"{"value":1}"#)),
            HTTPRoute.systemVolume(device: nil, value: 1)
        )
    }

    // MARK: - Rejections

    func testRejectsAnOutOfRangeValue() {
        XCTAssertEqual(errorStatus(route("POST", "/api/system/volume", body: #"{"value":3}"#)), 400)
        XCTAssertEqual(errorStatus(route("POST", "/api/system/volume", body: #"{"value":-1}"#)), 400)
    }

    func testRejectsAMalformedOrEmptyBody() {
        XCTAssertEqual(errorStatus(route("POST", "/api/system/volume", body: "not json")), 400)
        XCTAssertEqual(errorStatus(route("POST", "/api/system/volume", body: #"{}"#)), 400)
    }

    func testRejectsAnUnknownDeviceShape() {
        // A non-numeric device is ignored, so this is a plain default-device
        // write rather than a 500 — but a missing value is still a 400.
        XCTAssertEqual(errorStatus(route("POST", "/api/system/volume", body: #"{"device":"speakers"}"#)), 400)
    }

    func testUnknownSystemResourceIs404() {
        XCTAssertEqual(errorStatus(route("GET", "/api/system/whatever")), 404)
        XCTAssertEqual(errorStatus(route("GET", "/api/system")), 404)
        // A deeper path is not a shape this API has.
        XCTAssertEqual(errorStatus(route("GET", "/api/system/volume/extra")), 404)
    }

    func testWrongMethodIs404() {
        XCTAssertEqual(errorStatus(route("POST", "/api/system/audio-devices")), 404)
        XCTAssertEqual(errorStatus(route("GET", "/api/system/volume/extra")), 404)
    }
}
