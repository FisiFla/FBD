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
    /// Whether *this* invocation goes over the app's HTTP API.
    ///
    /// A few invocations have no HTTP route — the ladder preview, the
    /// remembered-disconnect list and the below-floor blend's state — and
    /// answer from the settings the app and the CLI share. The decision
    /// lives in the plan builder, next to the request mapping it belongs to.
    static func canRoute(_ command: Command, args: [String]) -> Bool {
        HTTPRoutingPlanBuilder.hasRoute(command, args: args)
    }

    /// Route `command` over HTTP. Returns the exit code, or nil only when the
    /// app is not listening (caller falls back to direct execution). An app
    /// that is up but erroring, slow or rejecting the token yields exit 2.
    static func route(_ command: Command, args: [String]) -> Int32? {
        switch HTTPAPIClient.probe() {
        case .notRunning:
            return nil
        case .running:
            break
        case .unauthorized:
            print("fbdcli: the app rejected the API token (HTTP 401). Not falling back to direct control; "
                + "check the token with `fbdcli auth-token --reveal`, or pass --direct to bypass the app.")
            return 2
        case .unresponsive(let reason):
            print("fbdcli: the app's HTTP API is up but not usable (\(reason)). Not falling back to direct "
                + "control while the app may own the display bus; pass --direct to override.")
            return 2
        }
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
        case .hidpi: return routedHiDPI(rest)
        case .gammaFloor: return routedGammaFloor(rest)
        case .display: return routedDisplay(rest)
        default:
            // A command in supportedCommands without a routed handler is a
            // programming error — loud in debug, safe fallback in release.
            assertionFailure("routable command \(command) has no routed handler")
            return nil
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

    /// The outcome of a routed write.
    private enum WriteResult {
        /// The app confirmed the write; its JSON body is attached.
        case applied([String: Any])
        /// The write was not confirmed; the exit code to return.
        case failed(Int32)
    }

    /// Run a state-changing request.
    ///
    /// On success the app's JSON body is returned. On failure the CLI prints
    /// the write-failure wording — which says whether the command may have
    /// applied and names the command that reads the state back — and the
    /// exit code is returned. The wording never invites a blind retry: a lost
    /// reply means the write may already have been committed, and repeating
    /// it would apply the change twice.
    private static func write(
        _ path: String,
        _ payload: [String: Any],
        command: String,
        readBack: String?
    ) -> WriteResult {
        let response = HTTPAPIClient.post(path, json: payload)
        switch response.outcome {
        case .applied:
            return .applied(HTTPAPIClient.json(response.body) ?? [:])
        case .refused, .failed, .replyLost:
            let failure = WriteFailure(outcome: response.outcome, command: command, readBack: readBack)
            let message = failure.message
            log.warning("write not confirmed: \(message)")
            print(message)
            return .failed(failure.exitCode)
        }
    }

    /// The command that reads the state back, with the display id filled in.
    /// Every routed write has one; nil would mean the CLI cannot show it.
    private static func readBack(_ command: Command, _ id: String? = nil) -> String? {
        readBackCommand(command, id)
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
        // The hardware facts (EDID, panel, DPCD, link, connection), as the app
        // reports them.
        for entry in info["profileSummary"] as? [[String: Any]] ?? [] {
            guard let label = entry["label"] as? String else { continue }
            print("  \(label): \(entry["value"] as? String ?? "")")
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
        switch write(plan.path, plan.payload ?? [:], command: "brightness \(id)",
                     readBack: readBack(.brightness, id)) {
        case .failed(let code): return code
        case .applied: break
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
        switch write(plan.path, plan.payload ?? [:], command: "contrast \(id)",
                     readBack: readBack(.contrast, id)) {
        case .failed(let code): return code
        case .applied: break
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
        switch write(plan.path, plan.payload ?? [:], command: "volume \(id)",
                     readBack: readBack(.volume, id)) {
        case .failed(let code): return code
        case .applied: break
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
        switch write(plan.path, plan.payload ?? [:], command: "mute \(id)",
                     readBack: readBack(.mute, id)) {
        case .failed(let code): return code
        case .applied: break
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
        switch write(plan.path, plan.payload ?? [:], command: "input \(id)",
                     readBack: readBack(.input, id)) {
        case .failed(let code): return code
        case .applied: break
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
            let hidpi = (mode["hidpi"] as? Bool ?? false) ? "hidpi" : "lodpi"
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
        guard let id = args.first else { return 1 }
        switch write(plan.path, plan.payload ?? [:], command: "set-mode \(id)",
                     readBack: readBack(.setMode, id)) {
        case .failed(let code): return code
        case .applied(let object):
            guard let mode = object["mode"] as? String else {
                print("fbdcli: set-mode \(id): the app accepted the write but reported no mode")
                return 2
            }
            print("mode applied: \(mode) (via app)")
        }
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
        switch write(plan.path, plan.payload ?? [:], command: "xdr \(id)",
                     readBack: readBack(.xdr, id)) {
        case .failed(let code): return code
        case .applied: break
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
        switch write(plan.path, plan.payload ?? [:], command: "rotate \(id)",
                     readBack: readBack(.rotate, id)) {
        case .failed(let code): return code
        case .applied: break
        }
        print("display \(id) rotated to \(args[1])° (via app)")
        return 0
    }

    private static func routedFilter(_ args: [String]) -> Int32 {
        // Validate the LUT here too, not just in `cmdFilter`: this route never
        // reaches the direct path when the app is running, and the app's own 400
        // would only surface as a generic "failed to apply" message.
        if case .success(let parsed) = ScreenFilterArgs.parse(Array(args.dropFirst())),
           let lutPath = parsed.lutPath {
            do {
                _ = try LUTCubeParser.parse(contentsOf: URL(fileURLWithPath: lutPath))
            } catch {
                print("fbdcli: filter: LUT '\(lutPath)' is not usable: \(error)")
                return 1
            }
        }
        guard let plan = planFor(.filter, args) else { return 1 }
        guard let id = args.first else { return 1 }
        switch write(plan.path, plan.payload ?? [:], command: "filter \(id)",
                     readBack: readBack(.filter, id)) {
        case .failed(let code): return code
        case .applied: break
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
            switch write(plan.path, plan.payload ?? [:], command: "virtual create \(args[1])",
                         readBack: readBack(.virtual)) {
            case .failed(let code): return code
            case .applied(let object):
                print("virtual display created: \(object["displayID"] as? UInt32 ?? 0) (\(args[1])) via app")
            }
            return 0

        case "destroy":
            switch write(plan.path, plan.payload ?? [:], command: "virtual destroy \(originalName ?? "?")",
                         readBack: readBack(.virtual)) {
            case .failed(let code): return code
            case .applied: break
            }
            print("virtual screen '\(originalName ?? "?")' destroyed (via app)")
            return 0

        default:
            return 1
        }
    }

    // MARK: - The per-display state commands (#28)

    /// `fbdcli hidpi <id> install|remove|status` — the smooth-scaling ladder.
    ///
    /// The status is a read that travels over the same POST the write does:
    /// the app's route answers with the state itself. It is reported with the
    /// read wording, not the write wording — nothing was written, so nothing
    /// "may have applied".
    private static func routedHiDPI(_ args: [String]) -> Int32 {
        guard let plan = planFor(.hidpi, args) else { return 1 }
        guard let id = args.first else { return 1 }
        let operation = args.count >= 2 ? args[1].lowercased() : "status"

        if operation == "status" {
            let response = HTTPAPIClient.post(plan.path, json: plan.payload ?? [:])
            switch response.outcome {
            case .applied:
                let object = HTTPAPIClient.json(response.body) ?? [:]
                let status = HiDPIOverrideStatus(
                    isSupported: object["supported"] as? Bool ?? false,
                    isInstalled: object["installed"] as? Bool ?? false,
                    modeCount: object["modeCount"] as? Int ?? 0,
                    wouldPrompt: object["wouldPrompt"] as? Bool ?? false,
                    path: object["path"] as? String ?? ""
                )
                print("hidpi \(id): \(status.summary)")
                print("  override: \(status.path)")
                return 0
            case .refused, .failed, .replyLost:
                return reportReadFailure(outcome: response.outcome, command: "hidpi \(id) status")
            }
        }

        // The prompt for the administrator password appears while the app
        // runs the privileged step, so the heads-up comes before the request.
        switch operation {
        case "install":
            print("hidpi \(id): installing the smooth-scaling override — macOS will ask for an administrator password (via app)")
        case "remove":
            print("hidpi \(id): removing the smooth-scaling override — macOS will ask for an administrator password (via app)")
        default:
            break
        }

        switch write(plan.path, plan.payload ?? [:], command: "hidpi \(id) \(operation)",
                     readBack: readBack(.hidpi, id)) {
        case .failed(let code): return code
        case .applied: break
        }
        switch operation {
        case "install":
            print("hidpi \(id): the smooth-scaling override was written (via app)")
            print("  note: the display usually picks the ladder up on the next wake")
        case "remove":
            print("hidpi \(id): the smooth-scaling override was removed (via app)")
        default:
            break
        }
        return 0
    }

    /// `fbdcli gamma-floor <id> on|off [value]` — the below-floor brightness
    /// blend.
    ///
    /// The threshold the app applied is the one the CLI sent; when none was
    /// sent the configured one is kept, which the CLI says rather than
    /// guessing a number.
    private static func routedGammaFloor(_ args: [String]) -> Int32 {
        guard let plan = planFor(.gammaFloor, args) else { return 1 }
        guard let id = args.first else { return 1 }
        switch write(plan.path, plan.payload ?? [:], command: "gamma-floor \(id)",
                     readBack: readBack(.gammaFloor, id)) {
        case .failed(let code): return code
        case .applied: break
        }
        let enabled = (plan.payload?["enabled"] as? Bool) ?? false
        if let threshold = plan.payload?["threshold"] as? Double {
            print("gamma-floor \(id): \(enabled ? "on" : "off") (threshold \(Int((threshold * 100).rounded()))%) (via app)")
        } else {
            print("gamma-floor \(id): \(enabled ? "on" : "off") (threshold unchanged) (via app)")
        }
        return 0
    }

    /// `fbdcli display <id> disconnect|reconnect` — the display's place in the
    /// layout.
    private static func routedDisplay(_ args: [String]) -> Int32 {
        guard let plan = planFor(.display, args) else { return 1 }
        guard let id = args.first else { return 1 }
        let action = args.count >= 2 ? args[1].lowercased() : ""
        let remember = (plan.payload?["remember"] as? Bool) ?? false
        switch write(plan.path, plan.payload ?? [:], command: "display \(id) \(action)",
                     readBack: readBack(.display, id)) {
        case .failed(let code): return code
        case .applied: break
        }
        if action == "disconnect" {
            print("display \(id) disconnected (via app)")
            if remember {
                print("  remembered as off: it stays off when it is plugged back in")
                print("  verify the memory with: fbdcli display --list-remembered")
            }
        } else {
            print("display \(id) reconnected (via app)")
        }
        return 0
    }

    /// Report a request that changed nothing and did not come back.
    ///
    /// The write wording ("the command may have applied") belongs to a write
    /// whose confirmation was lost; a read that got no answer simply failed,
    /// and saying otherwise would send the caller looking for a change that
    /// was never asked for.
    private static func reportReadFailure(outcome: WriteOutcome, command: String) -> Int32 {
        let reason: String
        switch outcome {
        case .applied:
            return 0
        case .refused(let status):
            reason = "the app refused the request (HTTP \(status))"
        case .failed(let message):
            reason = message
        case .replyLost(let message):
            reason = "\(message) — nothing was changed"
        }
        print("fbdcli: \(command): \(reason)")
        return 2
    }
}
