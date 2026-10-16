import CoreGraphics
import CryptoKit
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
    /// The Mac's **own** audio (#20), not a display's.
    ///
    /// `systemVolume(device:value:)`: a nil `value` is a read, a value is a
    /// write, and a nil `device` means whatever the system default is.
    /// `AudioDeviceID` is a `UInt32`, spelled that way so this file needs no
    /// CoreAudio import.
    case systemVolume(device: UInt32?, value: Double?)
    case systemAudioDevices
    /// Settings-level configuration (the parity surfaces), not a display's
    /// hardware.
    ///
    /// These write through `Settings` — the single write path the app and
    /// `fbdcli` share — rather than through a controller, because that is
    /// genuinely where the values live. Both writes are read back at use time
    /// (lock dim re-reads its policy on every lock event, the media-key path
    /// reads the control target on every press), so neither needs a restart.
    /// `configLockDim` carries a nil `targetPercent` when the caller wants to
    /// change only the flag.
    case configStatus
    case configLockDim(enabled: Bool, targetPercent: Double?)
    case configKeyboardTarget(target: KeyboardControlTarget)
    /// Connection management: the same planner the Settings buttons and
    /// `fbdcli config connections` use, so HTTP cannot diverge from them.
    case configConnections(action: ConnectionAction)
    /// The per-display protection-property selection.
    case configProtection(displayID: CGDirectDisplayID, properties: ProtectedProperties)
    /// The saved TV / AVR registry — the one surface here that touches no
    /// display at all.
    case configDevice(DeviceAction)
    /// Resolution favourites: list them, record the current mode into a slot, or
    /// recall one. Recall reports an unmatched favourite rather than guessing.
    case configFavourite(displayID: CGDirectDisplayID, action: FavouriteAction)
    /// Named display presets: list them, capture the current state under a name,
    /// apply one, or delete one. Apply reports what the display no longer
    /// exposes rather than guessing.
    case configPreset(displayID: CGDirectDisplayID, action: PresetAction)
}

/// The favourite operations, so one route case carries them.
public enum FavouriteAction: Equatable {
    case list
    case save(slot: Int)
    case apply(slot: Int)
}

/// The preset operations. Apply and delete take a *reference* — a preset name or
/// its UUID — because that is what a caller has; the store resolves either.
public enum PresetAction: Equatable {
    case list
    case save(name: String, symbol: DisplayPresetSymbol, properties: ProtectedProperties)
    case apply(reference: String)
    case delete(reference: String)
}

/// The registry operations, so one route case carries them rather than three
/// near-identical ones.
public enum DeviceAction: Equatable {
    case list
    case add(name: String, brand: NetworkDevice.Brand, host: String, zone: String?)
    case remove(name: String)
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
    case rotate(Int)
    case filter(ScreenFilterParams)
    case filterOff
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
        guard Self.tokenMatches(provided, expectedToken) else {
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
        case "system":
            return routeSystem(method: method, components: components, body: body)
        case "config":
            return routeConfig(method: method, components: components, body: body)
        default:
            return .error(status: 404, message: "not found")
        }
    }

    /// Constant-time-ish token comparison: hashing both sides first makes
    /// the comparison independent of token length and prefix content, so a
    /// local attacker timing the endpoint learns nothing usable about the
    /// token (the digest `==` leaks at most an irrelevant digest byte).
    private static func tokenMatches(_ provided: String?, _ expected: String) -> Bool {
        guard let provided, !provided.isEmpty else { return false }
        let providedDigest = SHA256.hash(data: Data(provided.utf8))
        let expectedDigest = SHA256.hash(data: Data(expected.utf8))
        return providedDigest == expectedDigest
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
        case "rotate":
            guard let degrees = (object["degrees"] as? NSNumber)?.intValue,
                  [0, 90, 180, 270].contains(degrees) else {
                return .error(400, "degrees must be 0, 90, 180 or 270")
            }
            return .action(.rotate(degrees))
        case "filter":
            if let off = object["off"] as? Bool, off {
                return .action(.filterOff)
            }
            guard let contrast = (object["contrast"] as? NSNumber)?.doubleValue,
                  let saturation = (object["saturation"] as? NSNumber)?.doubleValue,
                  let gamma = (object["gamma"] as? NSNumber)?.doubleValue,
                  let temperature = (object["temperature"] as? NSNumber)?.doubleValue else {
                return .error(400, "expected contrast/saturation/gamma/temperature")
            }
            func optional(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
            // A LUT that cannot be parsed is refused outright. The overlay would
            // otherwise log the failure and skip the stage, leaving the caller
            // believing the colour correction had been applied — a silent
            // degrade on the one path where the input is user-supplied.
            let lutPath = (object["lutPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let lutPath {
                do {
                    _ = try LUTCubeParser.parse(contentsOf: URL(fileURLWithPath: lutPath))
                } catch {
                    return .error(400, "LUT is not usable")
                }
            }
            // The sharpening/geometry fields are optional; their ranges are
            // clamped by ScreenFilterParams, not here.
            return .action(.filter(ScreenFilterParams(
                contrast: contrast, saturation: saturation,
                gamma: gamma, temperature: temperature,
                invert: (object["invert"] as? Bool) ?? false,
                sharpness: optional("sharpness") ?? 0,
                unsharpRadius: optional("unsharpRadius") ?? 1,
                zoom: optional("zoom") ?? 1,
                offsetX: optional("offsetX") ?? 0,
                offsetY: optional("offsetY") ?? 0,
                lutPath: lutPath
            )))
        default:
            return .error(404, "unknown action '\(action)'")
        }
    }

    // MARK: - /api/virtual

    /// `/api/system/...` — the Mac's own audio (#20).
    ///
    /// Deliberately not under `/api/displays`: this controls the Mac's output,
    /// not a display's speakers. They are different devices reached by different
    /// mechanisms (CoreAudio HAL vs DDC), and conflating them is exactly what the
    /// issue asked to avoid.
    private static func routeSystem(method: String, components: [String], body: String?) -> HTTPRouteResult {
        guard components.count == 3 else {
            return .error(status: 404, message: "not found")
        }
        switch components[2] {
        case "audio-devices":
            guard method == "GET" else { return .error(status: 404, message: "not found") }
            return .route(.systemAudioDevices)

        case "volume":
            if method == "GET" {
                return .route(.systemVolume(device: nil, value: nil))
            }
            guard method == "POST" else { return .error(status: 404, message: "not found") }
            guard let body, let object = HTTPJSON.parse(body),
                  let value = (object["value"] as? NSNumber)?.doubleValue,
                  (0...1).contains(value) else {
                return .error(status: 400, message: "value must be a number between 0 and 1")
            }
            // An explicit device lets a caller target the built-in speakers when
            // the system default is an HDMI output with no volume control.
            let device = (object["device"] as? NSNumber).flatMap { UInt32(exactly: $0.uint32Value) }
            return .route(.systemVolume(device: device, value: value))

        default:
            return .error(status: 404, message: "not found")
        }
    }

    private static func routeVirtual(method: String, components: [String], body: String?) -> HTTPRouteResult {        if components.count == 2, method == "GET" {
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

    // MARK: - /api/config

    /// `/api/config/...` — the parity settings surfaces.
    ///
    /// Deliberately not under `/api/displays`: these are application settings,
    /// not a display's hardware, so they are reached by a different mechanism
    /// (`Settings`) and conflating them would misdescribe what a write does.
    private static func routeConfig(method: String, components: [String], body: String?) -> HTTPRouteResult {
        if components.count == 2, method == "GET" {
            return .route(.configStatus)
        }
        guard components.count == 3, method == "POST" else {
            return .error(status: 404, message: "not found")
        }
        guard let body, let object = HTTPJSON.parse(body) else {
            return .error(status: 400, message: "invalid JSON body")
        }
        switch components[2] {
        case "lockdim":
            guard let enabled = object["enabled"] as? Bool else {
                return .error(status: 400, message: "enabled is required")
            }
            // Omitting targetPercent keeps the stored one, so a caller can turn
            // dimming on or off without having to know or restate the level.
            var target: Double?
            if let raw = object["targetPercent"] {
                // Must exclude a real JSON boolean, or `true` would mean 1%.
                // `isJSONBoolean`, not `is Bool` — see its note: the numbers 0
                // and 1 also satisfy `is Bool` through NSNumber's bridging.
                guard !isJSONBoolean(raw),
                      let value = (raw as? NSNumber)?.doubleValue,
                      (0...100).contains(value) else {
                    return .error(status: 400, message: "targetPercent must be a number between 0 and 100")
                }
                target = value
            }
            return .route(.configLockDim(enabled: enabled, targetPercent: target))

        case "keytarget":
            guard let raw = object["target"] as? String,
                  let target = KeyboardControlTarget(rawValue: raw) else {
                let allowed = KeyboardControlTarget.allCases.map(\.rawValue).joined(separator: ", ")
                return .error(status: 400, message: "target must be one of \(allowed)")
            }
            return .route(.configKeyboardTarget(target: target))

        case "connections":
            guard let raw = object["action"] as? String,
                  let action = ConnectionAction(rawValue: raw) else {
                let allowed = ConnectionAction.allCases.map(\.rawValue).joined(separator: ", ")
                return .error(status: 400, message: "action must be one of \(allowed)")
            }
            return .route(.configConnections(action: action))

        case "protection":
            guard let displayID = displayID(from: object) else {
                return .error(status: 400, message: "display is required")
            }
            guard let names = object["properties"] as? [String] else {
                return .error(status: 400, message: "properties must be an array of property names")
            }
            // Parsed here, not in the executor, so an unknown name is a 400 with
            // the valid names rather than a silent partial selection.
            guard let properties = ProtectedProperties.parse(names.joined(separator: ",")) else {
                let allowed = ProtectedProperties.ordered.map(\.name).joined(separator: ", ")
                return .error(status: 400, message: "properties may only contain: \(allowed)")
            }
            return .route(.configProtection(displayID: displayID, properties: properties))

        case "favourite":
            guard let displayID = displayID(from: object) else {
                return .error(status: 400, message: "display is required")
            }
            guard let raw = object["action"] as? String else {
                return .error(status: 400, message: "action must be list, save or apply")
            }
            switch raw {
            case "list":
                return .route(.configFavourite(displayID: displayID, action: .list))
            case "save", "apply":
                // `isJSONBoolean` and not `is Bool`: slot 1 is valid, and the
                // number 1 also satisfies `is Bool` through NSNumber's bridging.
                guard let rawSlot = object["slot"], !isJSONBoolean(rawSlot),
                      let slot = (rawSlot as? NSNumber)?.intValue,
                      ModeFavourites.validSlots.contains(slot) else {
                    return .error(status: 400, message: "slot must be between 1 and \(ModeFavourites.slotCount)")
                }
                return .route(.configFavourite(
                    displayID: displayID,
                    action: raw == "save" ? .save(slot: slot) : .apply(slot: slot)
                ))
            default:
                return .error(status: 400, message: "action must be list, save or apply")
            }

        case "device":
            guard let raw = object["action"] as? String else {
                return .error(status: 400, message: "action must be list, add or remove")
            }
            switch raw {
            case "list":
                return .route(.configDevice(.list))
            case "add":
                guard let name = object["name"] as? String, !name.isEmpty,
                      let brandRaw = object["brand"] as? String,
                      let brand = NetworkDevice.Brand(rawValue: brandRaw),
                      let host = object["host"] as? String else {
                    let brands = NetworkDevice.Brand.allCases.map(\.rawValue).joined(separator: ", ")
                    return .error(status: 400, message: "name, brand (\(brands)) and host are required")
                }
                // The host is interpolated into a request URL by the controllers,
                // so an unusable one is refused here rather than stored to fail
                // later at use time.
                guard NetworkDeviceRegistry.validatedHost(host) != nil else {
                    return .error(status: 400, message: "'\(host)' is not a usable host — give a hostname or IP address, without a scheme, port or path")
                }
                return .route(.configDevice(.add(name: name, brand: brand, host: host, zone: object["zone"] as? String)))
            case "remove":
                guard let name = object["name"] as? String, !name.isEmpty else {
                    return .error(status: 400, message: "name is required")
                }
                return .route(.configDevice(.remove(name: name)))
            default:
                return .error(status: 400, message: "action must be list, add or remove")
            }

        case "preset":
            guard let displayID = displayID(from: object) else {
                return .error(status: 400, message: "display is required")
            }
            guard let raw = object["action"] as? String else {
                return .error(status: 400, message: "action must be list, save, apply or delete")
            }
            switch raw {
            case "list":
                return .route(.configPreset(displayID: displayID, action: .list))

            case "save":
                // The name is validated here, not in the executor, so an
                // unusable one is a 400 naming the rule rather than a save that
                // silently does nothing.
                guard let rawName = object["name"] as? String,
                      let name = DisplayPresets.sanitizedName(rawName) else {
                    return .error(status: 400, message: "name is required")
                }
                var symbol = DisplayPresetSymbol.default
                if let rawSymbol = object["symbol"] {
                    guard let text = rawSymbol as? String, let resolved = DisplayPresetSymbol(rawValue: text) else {
                        let allowed = DisplayPresetSymbol.all.map(\.symbolName).joined(separator: ", ")
                        return .error(status: 400, message: "symbol must be one of \(allowed)")
                    }
                    symbol = resolved
                }
                // Omitting `properties` keeps the default selection, so a caller
                // saving "everything about this display" need not list it.
                var properties = DisplayPresets.defaultProperties
                if let names = object["properties"] as? [String] {
                    guard let parsed = ProtectedProperties.parse(names.joined(separator: ",")) else {
                        let allowed = ProtectedProperties.ordered.map(\.name).joined(separator: ", ")
                        return .error(status: 400, message: "properties may only contain: \(allowed)")
                    }
                    properties = parsed
                }
                return .route(.configPreset(
                    displayID: displayID,
                    action: .save(name: name, symbol: symbol, properties: properties)
                ))

            case "apply", "delete":
                guard let reference = (object["id"] as? String ?? object["name"] as? String),
                      !reference.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return .error(status: 400, message: "id or name is required")
                }
                return .route(.configPreset(
                    displayID: displayID,
                    action: raw == "apply" ? .apply(reference: reference) : .delete(reference: reference)
                ))

            default:
                return .error(status: 400, message: "action must be list, save, apply or delete")
            }

        default:
            return .error(status: 404, message: "unknown action '\(components[2])'")
        }
    }

    /// A display id from a JSON body. Accepts a number or a numeric string, so a
    /// caller can pass back whatever `/api/displays` handed them.
    private static func displayID(from object: [String: Any]) -> CGDirectDisplayID? {
        guard let raw = object["display"], !isJSONBoolean(raw) else { return nil }
        if let number = raw as? NSNumber {
            return number.uint32Value
        }
        if let text = raw as? String {
            return HTTPJSON.parseDisplayID(text)
        }
        return nil
    }

    /// Whether a value parsed out of a JSON body is a boolean.
    ///
    /// `value is Bool` is the wrong test: Swift bridges `NSNumber` to `Bool`, so
    /// the numbers **0 and 1** also satisfy it. Using it to exclude booleans
    /// therefore rejects `{"display": 1}` — and display 1 is usually the main
    /// display — and `{"targetPercent": 1}`. Comparing the CoreFoundation type
    /// id is exact: JSON `true`/`false` parse to `CFBoolean`, numbers to
    /// `CFNumber`.
    private static func isJSONBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }
}
