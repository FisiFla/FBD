import CoreGraphics
import Foundation

// MARK: - The seam

/// The display-control surface the HTTP executor depends on. One adapter is
/// the real DisplayController; the second is a test fake — two adapters make
/// the seam real (the ExternalControlling pattern).
@MainActor
public protocol DisplayControlling: AnyObject {
    var displays: [Display] { get }
    func display(withID id: CGDirectDisplayID) -> Display?

    func getBrightness(for display: Display) -> Double?
    @discardableResult func setBrightness(_ value: Double, on display: Display) -> Bool
    func readDDCControls(for display: Display) -> DisplayController.DDCControls
    func readDDCCapabilities(for display: Display) -> DDC.DDCCapabilities?
    func setContrast(_ value: Double, on display: Display) -> Bool
    func setVolume(_ value: Double, on display: Display) -> Bool
    func setMuted(_ muted: Bool, on display: Display) -> Bool
    func setInputSource(_ source: UInt16, on display: Display) -> Bool
    func applyMode(_ mode: DisplayMode, to display: Display) -> Bool
    func setXDRUpscaleTarget(_ nits: Int, on display: Display) -> Bool
    func disableXDRUpscaling(on display: Display) -> Bool
    func setRotation(_ degrees: Int, on display: Display) -> Int?
    func setScreenFilter(_ params: ScreenFilterParams, on display: Display) -> Bool
    func stopScreenFilter(on display: Display)
    func activeBoostDisplayIDs() -> [UInt32]

    // Virtual displays — routed through the single VirtualScreenController so
    // CLI, HTTP and UI share one surface.
    var virtualScreens: [VirtualScreenInstance] { get }
    var virtualConfigs: [VirtualScreenConfig] { get }
    var virtualAvailable: Bool { get }
    @discardableResult func createVirtual(_ config: VirtualScreenConfig) -> Bool
    @discardableResult func destroyVirtual(id: String) -> Bool
    func virtualDisplayID(for id: String) -> CGDirectDisplayID?
}

extension DisplayController: DisplayControlling {
    public var virtualScreens: [VirtualScreenInstance] { VirtualScreenController.shared.screens }
    public var virtualConfigs: [VirtualScreenConfig] { VirtualScreenController.shared.configs }
    public var virtualAvailable: Bool { VirtualScreenController.shared.isAvailable }
    @discardableResult
    public func createVirtual(_ config: VirtualScreenConfig) -> Bool {
        VirtualScreenController.shared.create(config)
    }
    @discardableResult
    public func destroyVirtual(id: String) -> Bool {
        VirtualScreenController.shared.destroy(id: id)
    }
    public func virtualDisplayID(for id: String) -> CGDirectDisplayID? {
        VirtualScreenController.shared.displayID(for: id)
    }
}

// MARK: - The executor

/// Executes a parsed HTTP route against the display-control surface.
///
/// The whole HTTP API surface used to live in the app target's `AppCore`
/// (untestable — no test target for the app). Moved here so every route's
/// behavior is testable through the `DisplayControlling` seam with a fake;
/// the router (path → route) and this executor (route → action) are the two
/// halves of the local API, both in FBDCore.
@MainActor
public enum HTTPExecutor {
    /// Run `route` and produce the HTTP status + JSON body.
    public static func execute(
        _ route: HTTPRoute,
        controller: DisplayControlling,
        version: String
    ) -> (Int, String) {
        switch route {
        case .health:
            let boostIDs = controller.activeBoostDisplayIDs()
            return (200, HTTPJSON.encode([
                "ok": true,
                "version": version,
                "displays": controller.displays.count,
                "boostActive": boostIDs,
            ]))
        case .listDisplays:
            let list = controller.displays.map { HTTPJSON.display($0) }
            return (200, HTTPJSON.encode(["displays": list]))
        case .displayInfo(let id):
            guard let display = controller.display(withID: id) else {
                return (404, HTTPJSON.error("display not found"))
            }
            var info = HTTPJSON.display(display)
            // Live brightness when the model value is stale (nothing read it yet).
            if info["brightness"] == nil, let value = controller.getBrightness(for: display) {
                info["brightness"] = value
            }
            info["modes"] = display.modes.map { HTTPJSON.mode($0) }
            return (200, HTTPJSON.encode(info))
        case .displayControls(let id, let what):
            guard let display = controller.display(withID: id) else {
                return (404, HTTPJSON.error("display not found"))
            }
            switch what {
            case "controls":
                let controls = controller.readDDCControls(for: display)
                let json: [String: Any] = [
                    "contrast": controls.contrast as Any? ?? NSNull(),
                    "volume": controls.volume as Any? ?? NSNull(),
                    "muted": controls.muted as Any? ?? NSNull(),
                    "inputSource": controls.inputSource as Any? ?? NSNull(),
                ]
                return (200, HTTPJSON.encode(["displayID": display.id, "controls": json]))
            default: // "caps"
                if let caps = controller.readDDCCapabilities(for: display) {
                    return (200, HTTPJSON.encode(["displayID": display.id, "raw": caps.raw, "mccsVersion": caps.mccsVersion, "vcp": caps.vcpCodes.sorted().map { String(format: "0x%02X", $0) }]))
                }
                return (404, HTTPJSON.error("no capabilities for display"))
            }
        case .displayAction(let id, let action):
            guard let display = controller.display(withID: id) else {
                return (404, HTTPJSON.error("display not found"))
            }
            switch action {
            case .contrast(let value):
                guard controller.setContrast(value, on: display) else { return (500, HTTPJSON.error("write not accepted")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .brightness(let value):
                guard controller.setBrightness(value, on: display) else { return (500, HTTPJSON.error("no control path for display")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .volume(let value):
                guard controller.setVolume(value, on: display) else { return (500, HTTPJSON.error("write not accepted")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .mute(let muted):
                guard controller.setMuted(muted, on: display) else { return (500, HTTPJSON.error("write not accepted")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .input(let source):
                guard controller.setInputSource(source, on: display) else { return (500, HTTPJSON.error("write not accepted")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .mode(let width, let height, let hz):
                guard let mode = HTTPJSON.bestMode(matchingWidth: width, height: height, hz: hz, in: display) else {
                    return (404, HTTPJSON.error("no matching mode"))
                }
                guard controller.applyMode(mode, to: display) else {
                    return (500, HTTPJSON.error("mode switch failed"))
                }
                return (200, HTTPJSON.encode(["ok": true, "mode": mode.key]))
            case .xdr(let nits):
                guard controller.setXDRUpscaleTarget(nits, on: display) else { return (500, HTTPJSON.error("XDR upscaling failed")) }
                return (200, HTTPJSON.encode(["ok": true, "nits": nits]))
            case .xdrDisable:
                guard controller.disableXDRUpscaling(on: display) else { return (500, HTTPJSON.error("failed to disable XDR upscaling")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .rotate(let degrees):
                guard controller.setRotation(degrees, on: display) != nil else {
                    return (500, HTTPJSON.error("failed to rotate display"))
                }
                return (200, HTTPJSON.encode(["ok": true, "degrees": degrees]))
            case .filter(let params):
                guard controller.setScreenFilter(params, on: display) else {
                    return (500, HTTPJSON.error("failed to apply filter"))
                }
                return (200, HTTPJSON.encode(["ok": true]))
            case .filterOff:
                controller.stopScreenFilter(on: display)
                return (200, HTTPJSON.encode(["ok": true]))
            }
        case .virtualList:
            let screens = controller.virtualScreens.map { ["id": $0.id, "name": $0.config.name, "displayID": $0.displayID] }
            let configs = controller.virtualConfigs.map { ["id": $0.id, "name": $0.name] }
            return (200, HTTPJSON.encode(["screens": screens, "configs": configs]))
        case .virtualCreate(let request):
            guard controller.virtualAvailable else {
                return (500, HTTPJSON.error("virtual displays unavailable on this macOS"))
            }
            let config = VirtualScreenConfig(
                name: request.name,
                width: request.width,
                height: request.height,
                refreshRate: request.hz,
                isHDR: request.isHDR,
                autoConnect: true
            )
            guard controller.createVirtual(config) else {
                return (500, HTTPJSON.error("failed to create virtual display"))
            }
            let displayID = controller.virtualDisplayID(for: config.id) ?? 0
            return (201, HTTPJSON.encode(["ok": true, "id": config.id, "displayID": displayID]))
        case .virtualDestroy(let id):
            guard controller.destroyVirtual(id: id) else {
                return (404, HTTPJSON.error("no virtual display '\(id)'"))
            }
            return (200, HTTPJSON.encode(["ok": true]))
        }
    }
}
