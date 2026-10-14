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

    /// Regression: the boolean test must not catch the *numbers* 0 and 1. Swift
    /// bridges NSNumber to Bool, so `value is Bool` is true for both.
    func testLockDimAcceptsTheNumbersZeroAndOne() {
        XCTAssertEqual(
            route("POST", "/api/config/lockdim", body: #"{"enabled":true,"targetPercent":1}"#),
            .route(.configLockDim(enabled: true, targetPercent: 1))
        )
        XCTAssertEqual(
            route("POST", "/api/config/lockdim", body: #"{"enabled":true,"targetPercent":0}"#),
            .route(.configLockDim(enabled: true, targetPercent: 0))
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

    // MARK: - Connections

    func testConnectionsRoutesEachAction() {
        for action in ConnectionAction.allCases {
            XCTAssertEqual(
                route("POST", "/api/config/connections", body: #"{"action":"\#(action.rawValue)"}"#),
                .route(.configConnections(action: action))
            )
        }
    }

    func testConnectionsRejectsAnUnknownActionAndNamesTheValidOnes() {
        guard case .error(let status, let message) = route(
            "POST", "/api/config/connections", body: #"{"action":"nope"}"#
        ) else { return XCTFail("expected an error") }
        XCTAssertEqual(status, 400)
        XCTAssertTrue(message.contains("connectAll"), "should list the valid actions, got: \(message)")
    }

    func testConnectionsRequiresTheField() {
        guard case .error(let status, _) = route("POST", "/api/config/connections", body: "{}") else {
            return XCTFail("expected an error when action is absent")
        }
        XCTAssertEqual(status, 400)
    }

    // MARK: - Protection

    func testProtectionRoutesAListOfProperties() {
        XCTAssertEqual(
            route("POST", "/api/config/protection", body: #"{"display":1,"properties":["resolution","brightness"]}"#),
            .route(.configProtection(displayID: 1, properties: [.resolution, .brightness]))
        )
    }

    func testProtectionAcceptsAll() {
        XCTAssertEqual(
            route("POST", "/api/config/protection", body: #"{"display":1,"properties":["all"]}"#),
            .route(.configProtection(displayID: 1, properties: .all))
        )
    }

    /// A display id may arrive as a number or as the string `/api/displays` returned.
    func testProtectionAcceptsADisplayIDAsAString() {
        XCTAssertEqual(
            route("POST", "/api/config/protection", body: #"{"display":"7","properties":["preset"]}"#),
            .route(.configProtection(displayID: 7, properties: [.preset]))
        )
    }

    func testProtectionRejectsAnUnknownPropertyAndNamesTheValidOnes() {
        guard case .error(let status, let message) = route(
            "POST", "/api/config/protection", body: #"{"display":1,"properties":["resolution","nope"]}"#
        ) else { return XCTFail("expected an error") }
        XCTAssertEqual(status, 400)
        XCTAssertTrue(message.contains("brightness"), "should list valid properties, got: \(message)")
    }

    func testProtectionRejectsAMissingDisplay() {
        guard case .error(let status, _) = route(
            "POST", "/api/config/protection", body: #"{"properties":["resolution"]}"#
        ) else { return XCTFail("expected an error when display is absent") }
        XCTAssertEqual(status, 400)
    }

    /// A JSON boolean bridges to NSNumber, so `true` must not read as display 1.
    func testProtectionRejectsABooleanDisplay() {
        guard case .error(let status, _) = route(
            "POST", "/api/config/protection", body: #"{"display":true,"properties":["resolution"]}"#
        ) else { return XCTFail("expected an error for a boolean display") }
        XCTAssertEqual(status, 400)
    }

    // MARK: - Devices

    func testDeviceList() {
        XCTAssertEqual(
            route("POST", "/api/config/device", body: #"{"action":"list"}"#),
            .route(.configDevice(.list))
        )
    }

    func testDeviceAdd() {
        XCTAssertEqual(
            route("POST", "/api/config/device", body: #"{"action":"add","name":"TV","brand":"lg","host":"tv.lan"}"#),
            .route(.configDevice(.add(name: "TV", brand: .lg, host: "tv.lan", zone: nil)))
        )
    }

    func testDeviceAddWithAZone() {
        XCTAssertEqual(
            route(
                "POST", "/api/config/device",
                body: #"{"action":"add","name":"Amp","brand":"yamaha","host":"amp.lan","zone":"2"}"#
            ),
            .route(.configDevice(.add(name: "Amp", brand: .yamaha, host: "amp.lan", zone: "2")))
        )
    }

    /// The host is interpolated into a request URL by the controllers, so an
    /// unusable one is refused here rather than stored to fail at use time.
    func testDeviceAddRejectsAnUnusableHost() {
        guard case .error(let status, _) = route(
            "POST", "/api/config/device",
            body: #"{"action":"add","name":"TV","brand":"lg","host":"http://tv.lan"}"#
        ) else { return XCTFail("expected an error for an unusable host") }
        XCTAssertEqual(status, 400)
    }

    func testDeviceAddRejectsAnUnknownBrandAndNamesTheValidOnes() {
        guard case .error(let status, let message) = route(
            "POST", "/api/config/device",
            body: #"{"action":"add","name":"TV","brand":"sony","host":"tv.lan"}"#
        ) else { return XCTFail("expected an error for an unknown brand") }
        XCTAssertEqual(status, 400)
        XCTAssertTrue(message.contains("lg"), "should list valid brands, got: \(message)")
    }

    func testDeviceRemove() {
        XCTAssertEqual(
            route("POST", "/api/config/device", body: #"{"action":"remove","name":"TV"}"#),
            .route(.configDevice(.remove(name: "TV")))
        )
    }

    func testDeviceRejectsAnUnknownAction() {
        guard case .error(let status, let message) = route(
            "POST", "/api/config/device", body: #"{"action":"nope"}"#
        ) else { return XCTFail("expected an error") }
        XCTAssertEqual(status, 400)
        XCTAssertTrue(message.contains("remove"), "should name the valid actions, got: \(message)")
    }

    // MARK: - Resolution favourites

    func testFavouriteList() {
        XCTAssertEqual(
            route("POST", "/api/config/favourite", body: #"{"display":1,"action":"list"}"#),
            .route(.configFavourite(displayID: 1, action: .list))
        )
    }

    /// Slot 1 is valid, and the number 1 also satisfies `is Bool` through
    /// NSNumber's bridging — so this is the same trap as the display-id one.
    func testFavouriteAcceptsSlotOne() {
        XCTAssertEqual(
            route("POST", "/api/config/favourite", body: #"{"display":1,"action":"save","slot":1}"#),
            .route(.configFavourite(displayID: 1, action: .save(slot: 1)))
        )
    }

    func testFavouriteAcceptsTheLastSlot() {
        XCTAssertEqual(
            route("POST", "/api/config/favourite", body: #"{"display":1,"action":"apply","slot":5}"#),
            .route(.configFavourite(displayID: 1, action: .apply(slot: 5)))
        )
    }

    func testFavouriteRejectsAnOutOfRangeSlot() {
        for slot in ["0", "6", "-1"] {
            guard case .error(let status, _) = route(
                "POST", "/api/config/favourite",
                body: #"{"display":1,"action":"apply","slot":\#(slot)}"#
            ) else { return XCTFail("expected an error for slot \(slot)") }
            XCTAssertEqual(status, 400)
        }
    }

    func testFavouriteRejectsABooleanSlot() {
        guard case .error(let status, _) = route(
            "POST", "/api/config/favourite", body: #"{"display":1,"action":"save","slot":true}"#
        ) else { return XCTFail("expected an error for a boolean slot") }
        XCTAssertEqual(status, 400)
    }

    func testFavouriteRequiresTheSlotForSaveAndApply() {
        guard case .error(let status, _) = route(
            "POST", "/api/config/favourite", body: #"{"display":1,"action":"save"}"#
        ) else { return XCTFail("expected an error when slot is absent") }
        XCTAssertEqual(status, 400)
    }

    func testFavouriteRejectsAnUnknownAction() {
        guard case .error(let status, let message) = route(
            "POST", "/api/config/favourite", body: #"{"display":1,"action":"nope"}"#
        ) else { return XCTFail("expected an error") }
        XCTAssertEqual(status, 400)
        XCTAssertTrue(message.contains("apply"), "should name the valid actions, got: \(message)")
    }
}
