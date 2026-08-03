import Foundation

/// The HTTP request a routed CLI command maps to (method, path, JSON body).
/// Equatable via NSDictionary comparison so tests can assert payloads.
public struct HTTPRoutingPlan: Equatable {
    public let method: String
    public let path: String
    public let payload: [String: Any]?

    public init(method: String, path: String, payload: [String: Any]?) {
        self.method = method
        self.path = path
        self.payload = payload
    }

    public static func == (lhs: HTTPRoutingPlan, rhs: HTTPRoutingPlan) -> Bool {
        lhs.method == rhs.method
            && lhs.path == rhs.path
            && NSDictionary(dictionary: lhs.payload ?? [:]).isEqual(to: rhs.payload ?? [:])
    }
}

/// Usage/validation error carrying the CLI's exact message.
public struct HTTPRoutingError: Error, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// Pure mapping from CLI command arguments to the app's HTTP API requests.
///
/// The routed CLI commands (`fbdcli list`, `fbdcli brightness 1 60`, …) all
/// translate to a GET/POST on the app's local API. This builder is the
/// single source of that mapping — extracted from `fbdcli/HTTPRouting.swift`
/// so the URL/method/payload derivation and its validation are unit-tested
/// without a running app. Failures carry the exact usage message the CLI
/// prints.
public enum HTTPRoutingPlanBuilder {
    /// Plan the request for a routable command. `args` are the CLI arguments
    /// after the command word (same shape `HTTPRouting.route` receives).
    /// `.failure(message)` means invalid arguments; the message is the CLI's
    /// usage text.
    public static func plan(for command: Command, args: [String]) -> Result<HTTPRoutingPlan, HTTPRoutingError> {
        switch command {
        case .list:
            return .success(HTTPRoutingPlan(method: "GET", path: "/api/displays", payload: nil))

        case .info, .caps, .modes:
            guard let id = args.first else {
                return .failure(HTTPRoutingError(message: "fbdcli: \(command.rawValue): display id required"))
            }
            let path = "/api/displays/\(id)"
            let suffix = command == .caps ? "/caps" : ""
            return .success(HTTPRoutingPlan(method: "GET", path: path + suffix, payload: nil))

        case .brightness, .contrast, .volume:
            guard let id = args.first else {
                return .failure(HTTPRoutingError(message: "fbdcli: \(command.rawValue): display id required"))
            }
            guard args.count >= 2 else {
                // Read-back: the app's display JSON carries brightness;
                // contrast/volume live under /controls.
                let path = command == .brightness
                    ? "/api/displays/\(id)"
                    : "/api/displays/\(id)/controls"
                return .success(HTTPRoutingPlan(method: "GET", path: path, payload: nil))
            }
            guard let value = Double(args[1]), (0...100).contains(value) else {
                return .failure(HTTPRoutingError(message: "fbdcli: \(command.rawValue): expected 0-100"))
            }
            return .success(HTTPRoutingPlan(
                method: "POST",
                path: "/api/displays/\(id)/\(command.rawValue)",
                payload: ["value": value / 100.0]
            ))

        case .mute:
            guard let id = args.first else {
                return .failure(HTTPRoutingError(message: "fbdcli: mute: display id required"))
            }
            guard args.count >= 2 else {
                return .success(HTTPRoutingPlan(method: "GET", path: "/api/displays/\(id)/controls", payload: nil))
            }
            let muted: Bool
            switch args[1] {
            case "on": muted = true
            case "off": muted = false
            default:
                return .failure(HTTPRoutingError(message: "fbdcli: mute: expected on or off (got '\(args[1])')"))
            }
            return .success(HTTPRoutingPlan(
                method: "POST",
                path: "/api/displays/\(id)/mute",
                payload: ["muted": muted]
            ))

        case .input:
            guard let id = args.first else {
                return .failure(HTTPRoutingError(message: "fbdcli: input: display id required"))
            }
            guard args.count >= 2 else {
                return .success(HTTPRoutingPlan(method: "GET", path: "/api/displays/\(id)/controls", payload: nil))
            }
            guard let source = UInt16(args[1]) else {
                return .failure(HTTPRoutingError(message: "fbdcli: input: source must be a number (got '\(args[1])')"))
            }
            return .success(HTTPRoutingPlan(
                method: "POST",
                path: "/api/displays/\(id)/input",
                payload: ["source": source]
            ))

        case .setMode:
            guard let id = args.first, args.count >= 2 else {
                return .failure(HTTPRoutingError(message: "fbdcli: set-mode: expected <id> <W>x<H>[@<hz>]"))
            }
            let spec = args[1]
            let parts = spec.lowercased().split(separator: "@")
            let dims = parts[0].split(separator: "x")
            guard dims.count == 2, let width = Int(dims[0]), let height = Int(dims[1]) else {
                return .failure(HTTPRoutingError(message: "fbdcli: set-mode: expected <W>x<H>[@<hz>] (got '\(spec)')"))
            }
            let hz = parts.count > 1 ? Double(parts[1]) : nil
            var payload: [String: Any] = ["width": width, "height": height]
            if let hz { payload["hz"] = hz }
            return .success(HTTPRoutingPlan(method: "POST", path: "/api/displays/\(id)/mode", payload: payload))

        case .xdr:
            guard let id = args.first else {
                return .failure(HTTPRoutingError(message: "fbdcli: xdr: display id required"))
            }
            guard args.count >= 2 else {
                return .success(HTTPRoutingPlan(method: "GET", path: "/api/displays/\(id)", payload: nil))
            }
            if args[1] == "off" {
                return .success(HTTPRoutingPlan(method: "POST", path: "/api/displays/\(id)/xdr", payload: ["enabled": false]))
            }
            guard let nits = Int(args[1]), nits > 0 else {
                return .failure(HTTPRoutingError(message: "fbdcli: xdr: expected a nits value or 'off' (got '\(args[1])')"))
            }
            return .success(HTTPRoutingPlan(method: "POST", path: "/api/displays/\(id)/xdr", payload: ["nits": nits]))

        case .virtual:
            guard let action = args.first else {
                return .failure(HTTPRoutingError(message: "fbdcli: virtual: action required (list|create|destroy)"))
            }
            switch action {
            case "list":
                return .success(HTTPRoutingPlan(method: "GET", path: "/api/virtual", payload: nil))
            case "create":
                guard args.count >= 3 else {
                    return .failure(HTTPRoutingError(message: "fbdcli: virtual create: expected <name> <W>x<H>[@<hz>]"))
                }
                let name = args[1]
                let spec = args[2]
                let parts = spec.lowercased().split(separator: "@")
                let dims = parts[0].split(separator: "x")
                guard dims.count == 2, let width = UInt32(dims[0]), let height = UInt32(dims[1]) else {
                    return .failure(HTTPRoutingError(message: "fbdcli: virtual create: expected <W>x<H>[@<hz>] (got '\(spec)')"))
                }
                let hz = parts.count > 1 ? Double(parts[1]) : 60
                var payload: [String: Any] = ["name": name, "width": width, "height": height, "hz": hz]
                if args.contains("--hdr") { payload["isHDR"] = true }
                return .success(HTTPRoutingPlan(method: "POST", path: "/api/virtual/create", payload: payload))
            case "destroy":
                guard args.count >= 2 else {
                    return .failure(HTTPRoutingError(message: "fbdcli: virtual destroy: expected <id-or-name>"))
                }
                return .success(HTTPRoutingPlan(method: "POST", path: "/api/virtual/destroy", payload: ["id": args[1]]))
            default:
                return .failure(HTTPRoutingError(message: "fbdcli: virtual: unknown action '\(action)' (list|create|destroy)"))
            }

        default:
            // Non-routable commands are not planned here.
            return .failure(HTTPRoutingError(message: "fbdcli: \(command.rawValue): not routable"))
        }
    }
}
