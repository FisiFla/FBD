import XCTest
import FBDCore

/// Full-surface tests for the pure HTTP router: auth, method gate, path
/// syntax, body validation, and typed route mapping.
final class HTTPRouterTests: XCTestCase {
    private let token = "test-token"

    private func route(
        _ method: String,
        _ path: String,
        body: String? = nil,
        headers: [String: String] = [:]
    ) -> HTTPRouteResult {
        var h = headers
        if h["x-fbd-token"] == nil, h["authorization"] == nil {
            h["x-fbd-token"] = token
        }
        return HTTPRouter.route(method: method, path: path, body: body, headers: h, expectedToken: token)
    }

    // MARK: - Auth

    func testMissingTokenIsUnauthorized() {
        let result = HTTPRouter.route(
            method: "GET", path: "/api/displays", body: nil,
            headers: [:], expectedToken: token
        )
        XCTAssertEqual(result, .error(status: 401, message: "unauthorized"))
    }

    func testWrongTokenIsUnauthorized() {
        let result = HTTPRouter.route(
            method: "GET", path: "/api/displays", body: nil,
            headers: ["x-fbd-token": "wrong"], expectedToken: token
        )
        XCTAssertEqual(result, .error(status: 401, message: "unauthorized"))
    }

    func testBearerTokenAccepted() {
        let result = HTTPRouter.route(
            method: "GET", path: "/api/displays", body: nil,
            headers: ["authorization": "Bearer \(token)"], expectedToken: token
        )
        XCTAssertEqual(result, .route(.listDisplays))
    }

    // MARK: - Health (unauthenticated)

    func testHealthNeedsNoToken() {
        let result = HTTPRouter.route(
            method: "GET", path: "/api/health", body: nil,
            headers: [:], expectedToken: token
        )
        XCTAssertEqual(result, .route(.health))
    }

    func testHealthWorksWithWrongToken() {
        let result = HTTPRouter.route(
            method: "GET", path: "/api/health", body: nil,
            headers: ["x-fbd-token": "wrong"], expectedToken: token
        )
        XCTAssertEqual(result, .route(.health))
    }

    func testHealthIsGetOnly() {
        let result = HTTPRouter.route(
            method: "POST", path: "/api/health", body: nil,
            headers: [:], expectedToken: token
        )
        XCTAssertEqual(result, .error(status: 405, message: "method not allowed"))
    }

    // MARK: - Method gate

    func testUnsupportedMethodsAre405() {
        for method in ["PUT", "DELETE", "PATCH"] {
            XCTAssertEqual(route(method, "/api/displays"), .error(status: 405, message: "method not allowed"))
        }
    }

    // MARK: - Path syntax

    func testUnknownPathsAre404() {
        XCTAssertEqual(route("GET", "/"), .error(status: 404, message: "not found"))
        XCTAssertEqual(route("GET", "/nope"), .error(status: 404, message: "not found"))
        XCTAssertEqual(route("GET", "/api"), .error(status: 404, message: "not found"))
        XCTAssertEqual(route("GET", "/api/foo"), .error(status: 404, message: "not found"))
        XCTAssertEqual(route("GET", "/api/displays/1/brightness/extra"), .error(status: 404, message: "not found"))
    }

    func testListDisplays() {
        XCTAssertEqual(route("GET", "/api/displays"), .route(.listDisplays))
    }

    func testDisplayInfoAcceptsDecimalAndHexIDs() {
        XCTAssertEqual(route("GET", "/api/displays/7"), .route(.displayInfo(id: 7)))
        XCTAssertEqual(route("GET", "/api/displays/0x10"), .route(.displayInfo(id: 16)))
    }

    func testDisplayInfoRejectsUnparseableID() {
        XCTAssertEqual(route("GET", "/api/displays/abc"), .error(status: 404, message: "display not found"))
    }

    func testDisplayControlsAndCaps() {
        XCTAssertEqual(route("GET", "/api/displays/1/controls"), .route(.displayControls(id: 1, what: "controls")))
        XCTAssertEqual(route("GET", "/api/displays/1/caps"), .route(.displayControls(id: 1, what: "caps")))
        XCTAssertEqual(route("GET", "/api/displays/1/nonsense"), .error(status: 404, message: "unknown display info 'nonsense'"))
    }

    // MARK: - Display actions

    func testBrightnessActionValidation() {
        XCTAssertEqual(route("POST", "/api/displays/1/brightness", body: #"{"value":0.5}"#),
                       .route(.displayAction(id: 1, action: .brightness(0.5))))
        XCTAssertEqual(route("POST", "/api/displays/1/brightness", body: #"{"value":1.5}"#),
                       .error(status: 400, message: "value must be a number between 0 and 1"))
        XCTAssertEqual(route("POST", "/api/displays/1/brightness", body: #"{"value":"high"}"#),
                       .error(status: 400, message: "value must be a number between 0 and 1"))
    }

    func testContrastAndVolume() {
        XCTAssertEqual(route("POST", "/api/displays/1/contrast", body: #"{"value":0.25}"#),
                       .route(.displayAction(id: 1, action: .contrast(0.25))))
        XCTAssertEqual(route("POST", "/api/displays/1/volume", body: #"{"value":0.8}"#),
                       .route(.displayAction(id: 1, action: .volume(0.8))))
    }

    func testMuteValidation() {
        XCTAssertEqual(route("POST", "/api/displays/1/mute", body: #"{"muted":true}"#),
                       .route(.displayAction(id: 1, action: .mute(true))))
        // NSNumber bridges 0/1 to Bool (matches the pre-router behavior).
        XCTAssertEqual(route("POST", "/api/displays/1/mute", body: #"{"muted":1}"#),
                       .route(.displayAction(id: 1, action: .mute(true))))
        XCTAssertEqual(route("POST", "/api/displays/1/mute", body: #"{"muted":"yes"}"#),
                       .error(status: 400, message: "muted must be a boolean"))
    }

    func testInputSource() {
        XCTAssertEqual(route("POST", "/api/displays/1/input", body: #"{"source":17}"#),
                       .route(.displayAction(id: 1, action: .input(17))))
        XCTAssertEqual(route("POST", "/api/displays/1/input", body: #"{"source":"hdmi"}"#),
                       .error(status: 400, message: "source must be a number"))
    }

    func testModeValidation() {
        XCTAssertEqual(route("POST", "/api/displays/1/mode", body: #"{"width":1920,"height":1080}"#),
                       .route(.displayAction(id: 1, action: .mode(width: 1920, height: 1080, hz: nil))))
        XCTAssertEqual(route("POST", "/api/displays/1/mode", body: #"{"width":1920,"height":1080,"hz":60}"#),
                       .route(.displayAction(id: 1, action: .mode(width: 1920, height: 1080, hz: 60))))
        XCTAssertEqual(route("POST", "/api/displays/1/mode", body: #"{"width":1920}"#),
                       .error(status: 400, message: "width and height are required"))
    }

    func testXDRActions() {
        XCTAssertEqual(route("POST", "/api/displays/1/xdr", body: #"{"nits":1600}"#),
                       .route(.displayAction(id: 1, action: .xdr(nits: 1600))))
        XCTAssertEqual(route("POST", "/api/displays/1/xdr", body: #"{"enabled":false}"#),
                       .route(.displayAction(id: 1, action: .xdrDisable)))
        XCTAssertEqual(route("POST", "/api/displays/1/xdr", body: #"{"enabled":true}"#),
                       .error(status: 400, message: "expected {\"nits\": n} or {\"enabled\": false}"))
        XCTAssertEqual(route("POST", "/api/displays/1/xdr", body: #"{"nits":0}"#),
                       .error(status: 400, message: "expected {\"nits\": n} or {\"enabled\": false}"))
    }

    func testUnknownActionIs404() {
        XCTAssertEqual(route("POST", "/api/displays/1/frobnicate", body: #"{}"#),
                       .error(status: 404, message: "unknown action 'frobnicate'"))
    }

    func testMalformedJSONBodyIs400() {
        XCTAssertEqual(route("POST", "/api/displays/1/brightness", body: "not json"),
                       .error(status: 400, message: "invalid JSON body"))
        XCTAssertEqual(route("POST", "/api/displays/1/brightness", body: nil),
                       .error(status: 400, message: "invalid JSON body"))
    }

    // MARK: - Virtual

    func testVirtualList() {
        XCTAssertEqual(route("GET", "/api/virtual"), .route(.virtualList))
    }

    func testVirtualCreateValidation() {
        XCTAssertEqual(
            route("POST", "/api/virtual/create", body: #"{"name":"Test","width":1920,"height":1080}"#),
            .route(.virtualCreate(VirtualCreateRequest(name: "Test", width: 1920, height: 1080, hz: 60, isHDR: false)))
        )
        XCTAssertEqual(
            route("POST", "/api/virtual/create", body: #"{"name":"Test","width":1920,"height":1080,"hz":120,"isHDR":true}"#),
            .route(.virtualCreate(VirtualCreateRequest(name: "Test", width: 1920, height: 1080, hz: 120, isHDR: true)))
        )
        XCTAssertEqual(route("POST", "/api/virtual/create", body: #"{"name":"","width":1920,"height":1080}"#),
                       .error(status: 400, message: "name, width, and height are required"))
        XCTAssertEqual(route("POST", "/api/virtual/create", body: #"{"name":"Test","width":0,"height":1080}"#),
                       .error(status: 400, message: "name, width, and height are required"))
        XCTAssertEqual(route("POST", "/api/virtual/create", body: #"{"name":"Test"}"#),
                       .error(status: 400, message: "name, width, and height are required"))
    }

    func testVirtualDestroyValidation() {
        XCTAssertEqual(route("POST", "/api/virtual/destroy", body: #"{"id":"abc"}"#),
                       .route(.virtualDestroy(id: "abc")))
        XCTAssertEqual(route("POST", "/api/virtual/destroy", body: #"{"id":""}"#),
                       .error(status: 400, message: "id is required"))
        XCTAssertEqual(route("POST", "/api/virtual/nonsense", body: #"{}"#),
                       .error(status: 404, message: "unknown action 'nonsense'"))
    }

    func testVirtualRequiresJSONBody() {
        XCTAssertEqual(route("POST", "/api/virtual/create", body: nil),
                       .error(status: 400, message: "invalid JSON body"))
    }

    func testRotateActionParsing() {
        XCTAssertEqual(route("POST", "/api/displays/1/rotate", body: #"{"degrees": 90}"#),
                       .route(.displayAction(id: 1, action: .rotate(90))))
        XCTAssertEqual(route("POST", "/api/displays/1/rotate", body: #"{"degrees": 0}"#),
                       .route(.displayAction(id: 1, action: .rotate(0))))
        XCTAssertEqual(route("POST", "/api/displays/1/rotate", body: #"{"degrees": 45}"#),
                       .error(status: 400, message: "degrees must be 0, 90, 180 or 270"))
        XCTAssertEqual(route("POST", "/api/displays/1/rotate", body: #"{}"#),
                       .error(status: 400, message: "degrees must be 0, 90, 180 or 270"))
    }

    func testFilterActionParsing() {
        XCTAssertEqual(route("POST", "/api/displays/1/filter", body: #"{"contrast": 1, "saturation": 0, "gamma": 1, "temperature": 1}"#),
                       .route(.displayAction(id: 1, action: .filter(ScreenFilterParams(contrast: 1, saturation: 0, gamma: 1, temperature: 1)))))
        XCTAssertEqual(route("POST", "/api/displays/1/filter", body: #"{"off": true}"#),
                       .route(.displayAction(id: 1, action: .filterOff)))
        XCTAssertEqual(route("POST", "/api/displays/1/filter", body: #"{}"#),
                       .error(status: 400, message: "expected contrast/saturation/gamma/temperature"))
    }
}
