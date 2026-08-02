import CoreGraphics
import Foundation

/// Typed, validated HTTP API request produced by `HTTPRouter`. Execution
/// (controller access) stays in the app target; everything parseable and
/// checkable lives here so the whole surface is unit-testable.
public enum HTTPRoute: Equatable {
    case health
    case listDisplays
    case displayInfo(id: CGDirectDisplayID)
    case displayControls(id: CGDirectDisplayID, what: String)
    case displayAction(id: CGDirectDisplayID, action: DisplayAction)
    case virtualList
    case virtualCreate(VirtualCreateRequest)
    case virtualDestroy(id: String)
}

/// Validated display-control action (POST /api/displays/<id>/<action>).
public enum DisplayAction: Equatable {
    case contrast(Double)
    case brightness(Double)
    case volume(Double)
    case mute(Bool)
    case input(UInt16)
    case mode(width: Int32, height: Int32, hz: Double?)
    case xdr(nits: Int)
    case xdrDisable
}

/// Validated virtual-display creation request.
public struct VirtualCreateRequest: Equatable {
    public init(name: String, width: UInt32, height: UInt32, hz: Double, isHDR: Bool) {
        self.name = name
        self.width = width
        self.height = height
        self.hz = hz
        self.isHDR = isHDR
    }

    public let name: String
    public let width: UInt32
    public let height: UInt32
    public let hz: Double
    public let isHDR: Bool
}

public enum HTTPRouteResult: Equatable {
    case route(HTTPRoute)
    case error(status: Int, message: String)
}

/// Pure request routing for the local control API: authentication, method
/// gate, path syntax, and JSON body validation. No controller access — the
/// caller executes the returned route.
public enum HTTPRouter {
    /// Route a request. `headers` carry lowercased names; `expectedToken` is
    /// the local API token (Settings.httpAPIToken in the app).
    public static func route(
        method: String,
        path: String,
        body: String?,
        headers: [String: String],
        expectedToken: String
    ) -> HTTPRouteResult {
        // /api/health is the one unauthenticated endpoint (uptime/monitoring
        // checks from local tools that may not know the token).
        if path == "/api/health" {
            guard method == "GET" else {
                return .error(status: 405, message: "method not allowed")
            }
            return .route(.health)
        }

        // Local API token auth (fail closed).
        let provided = headers["x-fbd-token"] ?? headers["authorization"]
            .flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        guard provided == expectedToken else {
            return .error(status: 401, message: "unauthorized")
        }

        // The API is read/write over GET and POST only.
        guard method == "GET" || method == "POST" else {
            return .error(status: 405, message: "method not allowed")
        }

        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2, components[0] == "api" else {
            return .error(status: 404, message: "not found")
        }
        switch components[1] {
        case "displays":
            return routeDisplays(method: method, components: components, body: body)
        case "virtual":
            return routeVirtual(method: method, components: components, body: body)
        default:
            return .error(status: 404, message: "not found")
        }
    }

    // MARK: - /api/displays

    private static func routeDisplays(method: String, components: [String], body: String?) -> HTTPRouteResult {
        if components.count == 2, method == "GET" {
            return .route(.listDisplays)
        }
        if components.count == 3, method == "GET" {
            guard let id = HTTPJSON.parseDisplayID(components[2]) else {
                return .error(status: 404, message: "display not found")
            }
            return .route(.displayInfo(id: id))
        }
        if components.count == 4, method == "GET" {
            guard let id = HTTPJSON.parseDisplayID(components[2]) else {
                return .error(status: 404, message: "display not found")
            }
            let what = components[3]
            guard what == "controls" || what == "caps" else {
                return .error(status: 404, message: "unknown display info '\(what)'")
            }
            return .route(.displayControls(id: id, what: what))
        }
        if components.count == 4, method == "POST" {
            guard let id = HTTPJSON.parseDisplayID(components[2]) else {
                return .error(status: 404, message: "display not found")
            }
            switch validateAction(components[3], body: body) {
            case .action(let action):
                return .route(.displayAction(id: id, action: action))
            case .error(let status, let message):
                return .error(status: status, message: message)
            }
        }
        return .error(status: 404, message: "not found")
    }

    private enum ActionValidation {
        case action(DisplayAction)
        case error(Int, String)
    }

    private static func validateAction(_ action: String, body: String?) -> ActionValidation {
        guard let body, let object = HTTPJSON.parse(body) else {
            return .error(400, "invalid JSON body")
        }
        switch action {
        case "contrast":
            guard let value = object["value"] as? Double, (0...1).contains(value) else {
                return .error(400, "value must be a number between 0 and 1")
            }
            return .action(.contrast(value))
        case "brightness":
            guard let value = object["value"] as? Double, (0...1).contains(value) else {
                return .error(400, "value must be a number between 0 and 1")
            }
            return .action(.brightness(value))
        case "volume":
            guard let value = object["value"] as? Double, (0...1).contains(value) else {
                return .error(400, "value must be a number between 0 and 1")
            }
            return .action(.volume(value))
        case "mute":
            guard let muted = object["muted"] as? Bool else {
                return .error(400, "muted must be a boolean")
            }
            return .action(.mute(muted))
        case "input":
            guard let source = (object["source"] as? NSNumber).flatMap({ UInt16(exactly: $0.uint32Value) }) else {
                return .error(400, "source must be a number")
            }
            return .action(.input(source))
        case "mode":
            guard let width = (object["width"] as? NSNumber)?.int32Value,
                  let height = (object["height"] as? NSNumber)?.int32Value else {
                return .error(400, "width and height are required")
            }
            let hz = (object["hz"] as? NSNumber)?.doubleValue
            return .action(.mode(width: width, height: height, hz: hz))
        case "xdr":
            if let nits = (object["nits"] as? NSNumber)?.intValue, nits > 0 {
                return .action(.xdr(nits: nits))
            }
            if let enabled = object["enabled"] as? Bool, !enabled {
                return .action(.xdrDisable)
            }
            return .error(400, "expected {\"nits\": n} or {\"enabled\": false}")
        default:
            return .error(404, "unknown action '\(action)'")
        }
    }

    // MARK: - /api/virtual

    private static func routeVirtual(method: String, components: [String], body: String?) -> HTTPRouteResult {
        if components.count == 2, method == "GET" {
            return .route(.virtualList)
        }
        guard components.count == 3, method == "POST" else {
            return .error(status: 404, message: "not found")
        }
        guard let body, let object = HTTPJSON.parse(body) else {
            return .error(status: 400, message: "invalid JSON body")
        }
        switch components[2] {
        case "create":
            guard let name = object["name"] as? String, !name.isEmpty,
                  let width = (object["width"] as? NSNumber).flatMap({ UInt32(exactly: $0.uint32Value) }), width > 0,
                  let height = (object["height"] as? NSNumber).flatMap({ UInt32(exactly: $0.uint32Value) }), height > 0 else {
                return .error(status: 400, message: "name, width, and height are required")
            }
            let hz = (object["hz"] as? NSNumber)?.doubleValue ?? 60
            let isHDR = (object["isHDR"] as? Bool) ?? false
            return .route(.virtualCreate(VirtualCreateRequest(
                name: name,
                width: width,
                height: height,
                hz: hz,
                isHDR: isHDR
            )))
        case "destroy":
            guard let id = object["id"] as? String, !id.isEmpty else {
                return .error(status: 400, message: "id is required")
            }
            return .route(.virtualDestroy(id: id))
        default:
            return .error(status: 404, message: "unknown action '\(components[2])'")
        }
    }
}
