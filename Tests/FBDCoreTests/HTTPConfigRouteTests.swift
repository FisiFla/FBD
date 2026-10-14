import XCTest
@testable import FBDCore

/// `/api/config` routing: authentication, the method gate, and body validation.
///
/// Pure — `HTTPRouter` never touches a controller. The executor's writes go
/// through `Settings`, which the CLI and the app share, so they are exercised
/// where they live rather than here.
final class HTTPConfigRouteTests: XCTestCase {
    private let token = "test-token"

    private func route(
        _ method: String,
        _ path: String,
        body: String? = nil,
        token provided: String? = "test-token"
    ) -> HTTPRouteResult {
        let headers = provided.map { ["x-fbd-token": $0] } ?? [:]
        return HTTPRouter.route(
            method: method, path: path, body: body, headers: headers, expectedToken: token
        )
    }

    // MARK: - Reading

    func testGetStatusRoutes() {
        XCTAssertEqual(route("GET", "/api/config"), .route(.configStatus))
    }

    /// The token gate must not have been loosened for the new namespace.
    func testStatusRequiresTheToken() {
        XCTAssertEqual(
            route("GET", "/api/config", token: nil),
            .error(status: 401, message: "unauthorized")
        )
    }

    func testWritesRequireTheToken() {
        XCTAssertEqual(
            route("POST", "/api/config/lockdim", body: #"{"enabled":true}"#, token: nil),
            .error(status: 401, message: "unauthorized")
        )
    }

    // MARK: - Lock dim

    func testLockDimRoutesWithATarget() {
        XCTAssertEqual(
            route("POST", "/api/config/lockdim", body: #"{"enabled":true,"targetPercent":15}"#),
            .route(.configLockDim(enabled: true, targetPercent: 15))
        )
    }

    /// Omitting the target keeps the stored one, so toggling the flag cannot
    /// silently rewrite the level.
    func testLockDimWithoutATargetKeepsTheStoredOne() {
        XCTAssertEqual(
            route("POST", "/api/config/lockdim", body: #"{"enabled":false}"#),
            .route(.configLockDim(enabled: false, targetPercent: nil))
        )
    }

    func testLockDimRequiresEnabled() {
        XCTAssertEqual(
            route("POST", "/api/config/lockdim", body: #"{"targetPercent":15}"#),
            .error(status: 400, message: "enabled is required")
        )
    }

    func testLockDimRejectsAnOutOfRangeTarget() {
        for body in [#"{"enabled":true,"targetPercent":140}"#, #"{"enabled":true,"targetPercent":-1}"#] {
            XCTAssertEqual(
                route("POST", "/api/config/lockdim", body: body),
                .error(status: 400, message: "targetPercent must be a number between 0 and 100"),
                "body \(body) should have been refused"
            )
        }
    }

    /// A JSON boolean bridges to NSNumber, so `true` must not mean 1%.
    func testLockDimRejectsABooleanTarget() {
        XCTAssertEqual(
            route("POST", "/api/config/lockdim", body: #"{"enabled":true,"targetPercent":true}"#),
            .error(status: 400, message: "targetPercent must be a number between 0 and 100")
        )
    }

    // MARK: - Keyboard control target

    func testKeyboardTargetRoutes() {
        for target in KeyboardControlTarget.allCases {
            XCTAssertEqual(
                route("POST", "/api/config/keytarget", body: #"{"target":"\#(target.rawValue)"}"#),
                .route(.configKeyboardTarget(target: target))
            )
        }
    }

    func testKeyboardTargetRejectsAnUnknownName() {
        guard case .error(let status, let message) = route(
            "POST", "/api/config/keytarget", body: #"{"target":"nope"}"#
        ) else {
            return XCTFail("expected an error for an unknown target")
        }
        XCTAssertEqual(status, 400)
        // The message must name the valid values, or a caller cannot recover.
        XCTAssertTrue(
            message.contains("mouseScreen"),
            "the error should list the valid targets, got: \(message)"
        )
    }

    func testKeyboardTargetRequiresTheField() {
        guard case .error(let status, _) = route("POST", "/api/config/keytarget", body: "{}") else {
            return XCTFail("expected an error when target is absent")
        }
        XCTAssertEqual(status, 400)
    }

    // MARK: - Gate

    func testUnknownConfigActionIsNotFound() {
        XCTAssertEqual(
            route("POST", "/api/config/nope", body: "{}"),
            .error(status: 404, message: "unknown action 'nope'")
        )
    }

    func testInvalidJSONIsRejected() {
        XCTAssertEqual(
            route("POST", "/api/config/lockdim", body: "not json"),
            .error(status: 400, message: "invalid JSON body")
        )
    }

    func testMethodGate() {
        XCTAssertEqual(route("DELETE", "/api/config"), .error(status: 405, message: "method not allowed"))
        XCTAssertEqual(route("GET", "/api/config/lockdim"), .error(status: 404, message: "not found"))
        XCTAssertEqual(route("GET", "/api/config/keytarget"), .error(status: 404, message: "not found"))
    }
}
