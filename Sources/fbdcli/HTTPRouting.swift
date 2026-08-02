import FBDCore
import FBDCLIParser
import Foundation

/// Routed command implementations: the command runs against the app's HTTP API
/// instead of direct controllers, so the CLI never touches the DDC bus while
/// the app owns it. Output mirrors the direct commands' style.
@MainActor
enum HTTPRouting {
    /// Commands that can be routed through the app's HTTP API.
    static let routable: Set<Command> = [
        .list, .info, .brightness, .contrast, .volume, .mute, .input,
        .caps, .modes, .setMode, .xdr, .virtual,
    ]

    /// Route `command` over HTTP. Returns the exit code, or nil when the app
    /// is not running (caller falls back to direct execution).
    static func route(_ command: Command, args: [String]) -> Int32? {
        guard HTTPAPIClient.isAppRunning() else { return nil }
        let rest = Array(args.dropFirst())
        switch command {
        case .list: return routedList()
        case .info: return routedInfo(rest)
        case .brightness: return routedBrightness(rest)
        case .contrast: return routedContrast(rest)
        case .volume: return routedVolume(rest)
        case .mute: return routedMute(rest)
        case .input: return routedInput(rest)
        case .caps: return routedCaps(rest)
        case .modes: return routedModes(rest)
        case .setMode: return routedSetMode(rest)
        case .xdr: return routedXDR(rest)
        case .virtual: return routedVirtual(rest)
        default: return nil
        }
    }

    // MARK: - Helpers

    private static func displayJSON(_ id: String) -> [String: Any]? {
        guard let (status, data) = HTTPAPIClient.get("/api/displays/\(id)"), status == 200 else {
            return nil
        }
        return HTTPAPIClient.json(data)
    }

    private static func displaysJSON() -> [[String: Any]]? {
        guard let (status, data) = HTTPAPIClient.get("/api/displays"), status == 200,
              let object = HTTPAPIClient.json(data) else {
            return nil
        }
        return object["displays"] as? [[String: Any]]
    }

    private static func controlsJSON(_ id: String) -> [String: Any]? {
        guard let (status, data) = HTTPAPIClient.get("/api/displays/\(id)/controls"), status == 200,
              let object = HTTPAPIClient.json(data) else {
            return nil
        }
        return object["controls"] as? [String: Any]
    }

    private static func postOK(_ path: String, _ json: [String: Any]) -> Bool {
        guard let (status, _) = HTTPAPIClient.post(path, json: json) else { return false }
        return status == 200 || status == 201
    }

    // MARK: - Routed commands

    private static func routedList() -> Int32 {
        guard let displays = displaysJSON() else {
            print("fbdcli: app HTTP API unreachable")
            return 2
        }
        for display in displays {
            let id = display["id"] as? UInt32 ?? 0
            let name = display["name"] as? String ?? "?"
            let kind = (display["builtin"] as? Bool ?? false) ? "builtin"
                : (display["virtual"] as? Bool ?? false) ? "virtual" : "external"
            let mode = display["currentMode"] as? String ?? "—"
            let ddc = (display["ddc"] as? Bool ?? false) ? "yes" : "no"
            let apple = (display["appleBrightness"] as? Bool ?? false) ? "yes" : "no"
            let brightness = display["brightness"] as? Double
            var line = "\(id)  \(name)  \(kind)  \(mode)  ddc:\(ddc)  apple:\(apple)"
            if let brightness { line += String(format: "  bri:%.0f%%", brightness * 100) }
            print(line)
        }
        return 0
    }

    private static func routedInfo(_ args: [String]) -> Int32 {
        guard let id = args.first else {
            print("fbdcli: info: display id required")
            return 1
        }
        guard let info = displayJSON(id) else {
            print("fbdcli: display \(id) not found via app")
            return 2
        }
        print("Display \(info["id"] ?? "?")")
        print("  name: \(info["name"] as? String ?? "?")")
        print("  builtin: \((info["builtin"] as? Bool ?? false) ? "yes" : "no")  virtual: \((info["virtual"] as? Bool ?? false) ? "yes" : "no")")
        print("  currentMode: \(info["currentMode"] as? String ?? "—")")
        print("  ddc: \((info["ddc"] as? Bool ?? false) ? "yes" : "no")  appleBrightness: \((info["appleBrightness"] as? Bool ?? false) ? "yes" : "no")")
        if let brightness = info["brightness"] as? Double {
            print(String(format: "  brightness: %.1f%%", brightness * 100))
        }
        if let modes = info["modes"] as? [[String: Any]] {
            print("  modes: \(modes.count)")
        }
        return 0
    }

    private static func routedBrightness(_ args: [String]) -> Int32 {
        guard let id = args.first else {
            print("fbdcli: brightness: display id required")
            return 1
        }
        if args.count >= 2 {
            guard let value = Double(args[1]), (0...100).contains(value) else {
                print("fbdcli: brightness: expected 0-100")
                return 1
            }
            guard postOK("/api/displays/\(id)/brightness", ["value": value / 100.0]) else {
                print("fbdcli: brightness \(id): write not accepted (via app)")
                return 2
            }
            print("brightness \(id) = \(String(format: "%.1f", value)) (via app)")
            return 0
        }
        guard let info = displayJSON(id), let brightness = info["brightness"] as? Double else {
            print("fbdcli: brightness \(id): no read-back available")
            return 2
        }
        print(String(format: "%.1f", brightness * 100))
        return 0
    }

    private static func routedContrast(_ args: [String]) -> Int32 {
        guard let id = args.first else {
            print("fbdcli: contrast: display id required")
            return 1
        }
        if args.count >= 2 {
            guard let value = Double(args[1]), (0...100).contains(value) else {
                print("fbdcli: contrast: expected 0-100")
                return 1
            }
            guard postOK("/api/displays/\(id)/contrast", ["value": value / 100.0]) else {
                print("fbdcli: contrast \(id): write not accepted (via app)")
                return 2
            }
            print("contrast \(id) = \(String(format: "%.1f", value)) (via app)")
            return 0
        }
        guard let controls = controlsJSON(id), let value = controls["contrast"] as? Double else {
            print("fbdcli: contrast \(id): no read-back available")
            return 2
        }
        print(String(format: "%.1f", value * 100))
        return 0
    }

    private static func routedVolume(_ args: [String]) -> Int32 {
        guard let id = args.first else {
            print("fbdcli: volume: display id required")
            return 1
        }
        if args.count >= 2 {
            guard let value = Double(args[1]), (0...100).contains(value) else {
                print("fbdcli: volume: expected 0-100")
                return 1
            }
            guard postOK("/api/displays/\(id)/volume", ["value": value / 100.0]) else {
                print("fbdcli: volume \(id): write not accepted (via app)")
                return 2
            }
            print("volume \(id) = \(String(format: "%.1f", value)) (via app)")
            return 0
        }
        guard let controls = controlsJSON(id), let value = controls["volume"] as? Double else {
            print("fbdcli: volume \(id): no read-back available")
            return 2
        }
        print(String(format: "%.1f", value * 100))
        return 0
    }

    private static func routedMute(_ args: [String]) -> Int32 {
        guard let id = args.first else {
            print("fbdcli: mute: display id required")
            return 1
        }
        if args.count >= 2 {
            let muted: Bool
            switch args[1] {
            case "on": muted = true
            case "off": muted = false
            default:
                print("fbdcli: mute: expected on or off (got '\(args[1])')")
                return 1
            }
            guard postOK("/api/displays/\(id)/mute", ["muted": muted]) else {
                print("fbdcli: mute \(id): write not accepted (via app)")
                return 2
            }
            print("mute \(id) = \(muted ? "on" : "off") (via app)")
            return 0
        }
        guard let controls = controlsJSON(id), let muted = controls["muted"] as? Bool else {
            print("fbdcli: mute \(id): no read-back available")
            return 2
        }
        print(muted ? "on" : "off")
        return 0
    }

    private static func routedInput(_ args: [String]) -> Int32 {
        guard let id = args.first else {
            print("fbdcli: input: display id required")
            return 1
        }
        if args.count >= 2 {
            guard let source = UInt16(args[1]) else {
                print("fbdcli: input: source must be a number (got '\(args[1])')")
                return 1
            }
            guard postOK("/api/displays/\(id)/input", ["source": source]) else {
                print("fbdcli: input \(id): write not accepted (via app)")
                return 2
            }
            print("input \(id) = \(source) (via app)")
            return 0
        }
        guard let controls = controlsJSON(id), let source = controls["inputSource"] as? Double else {
            print("fbdcli: input \(id): no read-back available")
            return 2
        }
        print(Int(source))
        return 0
    }

    private static func routedCaps(_ args: [String]) -> Int32 {
        guard let id = args.first else {
            print("fbdcli: caps: display id required")
            return 1
        }
        guard let (status, data) = HTTPAPIClient.get("/api/displays/\(id)/caps"), status == 200,
              let object = HTTPAPIClient.json(data) else {
            print("fbdcli: caps \(id): no capabilities available (via app)")
            return 2
        }
        print("raw: \(object["raw"] as? String ?? "?")")
        if let mccs = object["mccsVersion"] as? String { print("mccs: \(mccs)") }
        if let vcp = object["vcp"] as? [String] { print("vcp: \(vcp.joined(separator: " "))") }
        return 0
    }

    private static func routedModes(_ args: [String]) -> Int32 {
        guard let id = args.first else {
            print("fbdcli: modes: display id required")
            return 1
        }
        guard let info = displayJSON(id), let modes = info["modes"] as? [[String: Any]] else {
            print("fbdcli: modes \(id): not found via app")
            return 2
        }
        let current = info["currentMode"] as? String
        for mode in modes {
            let width = mode["width"] as? Int ?? 0
            let height = mode["height"] as? Int ?? 0
            let hz = mode["hz"] as? Double ?? 0
            let hidpi = (mode["hidpi"] as? Bool ?? false) ? "hidpi" : "sdr"
            let safe = (mode["safe"] as? Bool ?? false) ? "safe" : ""
            let key = mode["key"] as? String ?? ""
            var line = String(format: "%dx%d@%.2f  %@  %@", width, height, hz, hidpi, safe)
            if key == current { line += "  current" }
            print(line)
        }
        return 0
    }

    private static func routedSetMode(_ args: [String]) -> Int32 {
        guard let id = args.first, args.count >= 2 else {
            print("fbdcli: set-mode: expected <id> <W>x<H>[@<hz>]")
            return 1
        }
        let spec = args[1]
        let parts = spec.lowercased().split(separator: "@")
        let dims = parts[0].split(separator: "x")
        guard dims.count == 2, let width = Int(dims[0]), let height = Int(dims[1]) else {
            print("fbdcli: set-mode: expected <W>x<H>[@<hz>] (got '\(spec)')")
            return 1
        }
        let hz = parts.count > 1 ? Double(parts[1]) : nil
        var body: [String: Any] = ["width": width, "height": height]
        if let hz { body["hz"] = hz }
        guard let (status, data) = HTTPAPIClient.post("/api/displays/\(id)/mode", json: body),
              status == 200, let object = HTTPAPIClient.json(data) else {
            print("fbdcli: set-mode: no matching mode via app")
            return 2
        }
        print("mode applied: \(object["mode"] as? String ?? "?") (via app)")
        return 0
    }

    private static func routedXDR(_ args: [String]) -> Int32 {
        guard let id = args.first else {
            print("fbdcli: xdr: display id required")
            return 1
        }
        if args.count >= 2 {
            if args[1] == "off" {
                guard postOK("/api/displays/\(id)/xdr", ["enabled": false]) else {
                    print("fbdcli: xdr \(id): failed to disable upscaling (via app)")
                    return 2
                }
                print("xdr \(id): upscaling disabled (via app)")
                return 0
            }
            guard let nits = Int(args[1]), nits > 0 else {
                print("fbdcli: xdr: expected a nits value or 'off' (got '\(args[1])')")
                return 1
            }
            guard postOK("/api/displays/\(id)/xdr", ["nits": nits]) else {
                print("fbdcli: xdr \(id): failed to enable upscaling (via app)")
                return 2
            }
            print("xdr \(id): upscaling enabled to \(nits) nits (via app)")
            return 0
        }
        guard let info = displayJSON(id) else {
            print("fbdcli: xdr \(id): display not found via app")
            return 2
        }
        let capable = info["xdrCapable"] as? Bool ?? false
        let upscaled = info["xdrUpscaled"] as? Bool ?? false
        let target = info["xdrTargetNits"] as? Int
        print("xdr \(id): capable=\(capable ? "yes" : "no") upscaled=\(upscaled ? "yes" : "no")\(target.map { " (\($0) nits)" } ?? "")")
        return 0
    }

    private static func routedVirtual(_ args: [String]) -> Int32 {
        guard let action = args.first else {
            print("fbdcli: virtual: action required (list|create|destroy)")
            return 1
        }
        switch action {
        case "list":
            guard let (status, data) = HTTPAPIClient.get("/api/virtual"), status == 200,
                  let object = HTTPAPIClient.json(data) else {
                print("fbdcli: virtual list: app unreachable")
                return 2
            }
            let screens = object["screens"] as? [[String: Any]] ?? []
            let configs = object["configs"] as? [[String: Any]] ?? []
            for config in configs {
                let id = config["id"] as? String ?? "?"
                let name = config["name"] as? String ?? "?"
                let active = screens.contains { $0["id"] as? String == id }
                let displayID = screens.first { $0["id"] as? String == id }?["displayID"] as? UInt32
                print("\(id)  \(name)  \(active ? "active (display \(displayID ?? 0))" : "—")")
            }
            if screens.isEmpty { print("no active screens") }
            return 0
        case "create":
            guard args.count >= 3 else {
                print("fbdcli: virtual create: expected <name> <W>x<H>[@<hz>]")
                return 1
            }
            let name = args[1]
            let spec = args[2]
            let parts = spec.lowercased().split(separator: "@")
            let dims = parts[0].split(separator: "x")
            guard dims.count == 2, let width = UInt32(dims[0]), let height = UInt32(dims[1]) else {
                print("fbdcli: virtual create: expected <W>x<H>[@<hz>] (got '\(spec)')")
                return 1
            }
            let hz = parts.count > 1 ? Double(parts[1]) : 60
            var body: [String: Any] = ["name": name, "width": width, "height": height, "hz": hz]
            if args.contains("--hdr") { body["isHDR"] = true }
            guard let (status, data) = HTTPAPIClient.post("/api/virtual/create", json: body),
                  status == 201, let object = HTTPAPIClient.json(data) else {
                print("fbdcli: virtual create: failed via app")
                return 2
            }
            print("virtual display created: \(object["displayID"] as? UInt32 ?? 0) (\(name)) via app")
            return 0
        case "destroy":
            guard args.count >= 2 else {
                print("fbdcli: virtual destroy: expected <id-or-name>")
                return 1
            }
            guard postOK("/api/virtual/destroy", ["id": args[1]]) else {
                print("fbdcli: virtual destroy: no virtual display '\(args[1])' via app")
                return 2
            }
            print("virtual screen '\(args[1])' destroyed (via app)")
            return 0
        default:
            print("fbdcli: virtual: unknown action '\(action)' (list|create|destroy)")
            return 1
        }
    }
}
