import FBDCore
import FBDCLIParser
import Foundation

/// Routed command implementations: the command runs against the app's HTTP API
/// instead of direct controllers, so the CLI never touches the DDC bus while
/// the app owns it. Output mirrors the direct commands' style.
///
/// The request mapping (method/path/payload + argument validation) lives in
/// `HTTPRoutingPlanBuilder` (FBDCLIParser) and is unit-tested; these
/// functions only execute the plan and format output.
@MainActor
enum HTTPRouting {
    /// Commands that can be routed through the app's HTTP API.
    static let routable: Set<Command> = [
        .list, .info, .brightness, .contrast, .volume, .mute, .input,
        .caps, .modes, .setMode, .xdr, .virtual, .rotate, .filter,
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
        case .rotate: return routedRotate(rest)
        case .filter: return routedFilter(rest)
        default: return nil
        }
    }

    // MARK: - Helpers

    /// Plan a routed request; prints the usage error and returns nil on
    /// invalid arguments (the builder is the tested single source).
    private static func planFor(_ command: Command, _ args: [String]) -> HTTPRoutingPlan? {
        switch HTTPRoutingPlanBuilder.plan(for: command, args: args) {
        case .failure(let error):
            print(error.message)
            return nil
        case .success(let plan):
            return plan
        }
    }

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
            print("fbdcli: list: app unreachable")
            return 2
        }
        for display in displays {
            let id = display["id"] as? UInt32 ?? 0
            let name = display["name"] as? String ?? "?"
            let builtin = (display["builtin"] as? Bool ?? false) ? "builtin" : "external"
            let ddc = (display["ddc"] as? Bool ?? false) ? "ddc:yes" : "ddc:no"
            print("\(id)   \(name)  \(builtin)  \(ddc)")
        }
        return 0
    }

    private static func routedInfo(_ args: [String]) -> Int32 {
        guard let plan = planFor(.info, args) else { return 1 }
        guard let id = args.first else { return 1 }
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
        _ = plan
        return 0
    }

    private static func routedBrightness(_ args: [String]) -> Int32 {
        guard let plan = planFor(.brightness, args) else { return 1 }
        guard let id = args.first else { return 1 }
        if plan.method == "GET" {
            guard let info = displayJSON(id), let brightness = info["brightness"] as? Double else {
                print("fbdcli: brightness \(id): no read-back available")
                return 2
            }
            print(String(format: "%.1f", brightness * 100))
            return 0
        }
        guard postOK(plan.path, plan.payload ?? [:]) else {
            print("fbdcli: brightness \(id): write not accepted (via app)")
            return 2
        }
        print("brightness \(id) = \(String(format: "%.1f", Double(args[1]) ?? 0)) (via app)")
        return 0
    }

    private static func routedContrast(_ args: [String]) -> Int32 {
        guard let plan = planFor(.contrast, args) else { return 1 }
        guard let id = args.first else { return 1 }
        if plan.method == "GET" {
            guard let controls = controlsJSON(id), let value = controls["contrast"] as? Double else {
                print("fbdcli: contrast \(id): no read-back available")
                return 2
            }
            print(String(format: "%.1f", value * 100))
            return 0
        }
        guard postOK(plan.path, plan.payload ?? [:]) else {
            print("fbdcli: contrast \(id): write not accepted (via app)")
            return 2
        }
        print("contrast \(id) = \(String(format: "%.1f", Double(args[1]) ?? 0)) (via app)")
        return 0
    }

    private static func routedVolume(_ args: [String]) -> Int32 {
        guard let plan = planFor(.volume, args) else { return 1 }
        guard let id = args.first else { return 1 }
        if plan.method == "GET" {
            guard let controls = controlsJSON(id), let value = controls["volume"] as? Double else {
                print("fbdcli: volume \(id): no read-back available")
                return 2
            }
            print(String(format: "%.1f", value * 100))
            return 0
        }
        guard postOK(plan.path, plan.payload ?? [:]) else {
            print("fbdcli: volume \(id): write not accepted (via app)")
            return 2
        }
        print("volume \(id) = \(String(format: "%.1f", Double(args[1]) ?? 0)) (via app)")
        return 0
    }

    private static func routedMute(_ args: [String]) -> Int32 {
        guard let plan = planFor(.mute, args) else { return 1 }
        guard let id = args.first else { return 1 }
        if plan.method == "GET" {
            guard let controls = controlsJSON(id), let muted = controls["muted"] as? Bool else {
                print("fbdcli: mute \(id): no read-back available")
                return 2
            }
            print(muted ? "on" : "off")
            return 0
        }
        guard postOK(plan.path, plan.payload ?? [:]) else {
            print("fbdcli: mute \(id): write not accepted (via app)")
            return 2
        }
        print("mute \(id) = \(args[1] == "on" ? "on" : "off") (via app)")
        return 0
    }

    private static func routedInput(_ args: [String]) -> Int32 {
        guard let plan = planFor(.input, args) else { return 1 }
        guard let id = args.first else { return 1 }
        if plan.method == "GET" {
            guard let controls = controlsJSON(id), let source = controls["inputSource"] as? Double else {
                print("fbdcli: input \(id): no read-back available")
                return 2
            }
            print(Int(source))
            return 0
        }
        guard postOK(plan.path, plan.payload ?? [:]) else {
            print("fbdcli: input \(id): write not accepted (via app)")
            return 2
        }
        print("input \(id) = \(args[1]) (via app)")
        return 0
    }

    private static func routedCaps(_ args: [String]) -> Int32 {
        guard let plan = planFor(.caps, args) else { return 1 }
        guard let id = args.first else { return 1 }
        guard let (status, data) = HTTPAPIClient.get(plan.path), status == 200,
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
        guard let plan = planFor(.modes, args) else { return 1 }
        guard let id = args.first else { return 1 }
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
        _ = plan
        return 0
    }

    private static func routedSetMode(_ args: [String]) -> Int32 {
        guard let plan = planFor(.setMode, args) else { return 1 }
        guard let (status, data) = HTTPAPIClient.post(plan.path, json: plan.payload ?? [:]),
              status == 200, let object = HTTPAPIClient.json(data) else {
            print("fbdcli: set-mode: no matching mode via app")
            return 2
        }
        print("mode applied: \(object["mode"] as? String ?? "?") (via app)")
        return 0
    }

    private static func routedXDR(_ args: [String]) -> Int32 {
        guard let plan = planFor(.xdr, args) else { return 1 }
        guard let id = args.first else { return 1 }
        if plan.method == "GET" {
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
        guard postOK(plan.path, plan.payload ?? [:]) else {
            if args[1] == "off" {
                print("fbdcli: xdr \(id): failed to disable upscaling (via app)")
            } else {
                print("fbdcli: xdr \(id): failed to enable upscaling (via app)")
            }
            return 2
        }
        if args[1] == "off" {
            print("xdr \(id): upscaling disabled (via app)")
        } else {
            print("xdr \(id): upscaling enabled to \(Int(args[1]) ?? 0) nits (via app)")
        }
        return 0
    }

    private static func routedRotate(_ args: [String]) -> Int32 {
        guard let plan = planFor(.rotate, args) else { return 1 }
        guard let id = args.first else { return 1 }
        guard postOK(plan.path, plan.payload ?? [:]) else {
            print("fbdcli: rotate: failed to rotate display \(id) (via app)")
            return 2
        }
        print("display \(id) rotated to \(args[1])° (via app)")
        return 0
    }

    private static func routedFilter(_ args: [String]) -> Int32 {
        guard let plan = planFor(.filter, args) else { return 1 }
        guard let id = args.first else { return 1 }
        guard postOK(plan.path, plan.payload ?? [:]) else {
            print("fbdcli: filter: failed to apply filter (via app)")
            return 2
        }
        print(args.count >= 2 && args[1] == "off" ? "filter off (via app)" : "filter applied (via app)")
        return 0
    }

    private static func routedVirtual(_ args: [String]) -> Int32 {
        // The app matches destroy by persisted config id only — resolve a
        // name through the shared controller's configs first (same as the
        // direct path), then plan with the resolved id.
        var plannedArgs = args
        let originalName = args.count >= 2 ? args[1] : nil
        if args.first == "destroy", args.count >= 2 {
            let resolved = resolveVirtualConfig(VirtualScreenController.shared, args[1])?.id ?? args[1]
            plannedArgs[1] = resolved
        }
        guard let plan = planFor(.virtual, plannedArgs) else { return 1 }
        guard let action = args.first else { return 1 }

        switch action {
        case "list":
            guard let (status, data) = HTTPAPIClient.get(plan.path), status == 200,
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
            guard let (status, data) = HTTPAPIClient.post(plan.path, json: plan.payload ?? [:]),
                  status == 201, let object = HTTPAPIClient.json(data) else {
                print("fbdcli: virtual create: failed via app")
                return 2
            }
            print("virtual display created: \(object["displayID"] as? UInt32 ?? 0) (\(args[1])) via app")
            return 0

        case "destroy":
            guard postOK(plan.path, plan.payload ?? [:]) else {
                print("fbdcli: virtual destroy: no virtual display '\(originalName ?? "?")' via app")
                return 2
            }
            print("virtual screen '\(originalName ?? "?")' destroyed (via app)")
            return 0

        default:
            return 1
        }
    }
}
