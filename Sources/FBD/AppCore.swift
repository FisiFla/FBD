import AppKit
import FBDCore
import os

/// Composition root for the menu-bar app. Owns the controllers the UI drives
/// and wires notification-driven refreshes between FBDCore and the status item.
@MainActor
final class AppCore {
    let displayController = DisplayController.shared
    let statusItemController: StatusItemController

    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "App")
    private var observers: [NSObjectProtocol] = []

    init() {
        statusItemController = StatusItemController()
    }

    func start() {
        // Register first: displayController.start() posts .fbdDisplaysChanged
        // during its initial refresh — the status item must catch it so the
        // first popover shows the populated display list.
        observe(.fbdDisplaysChanged) { [weak self] in
            self?.statusItemController.refreshUI()
        }
        observe(.fbdDisplayUpdated) { [weak self] in
            self?.statusItemController.refreshUI()
        }

        displayController.start()
        statusItemController.install()

        // Tier 3 controllers: virtual screens, soft disconnect, layout protection.
        virtualScreens.start()
        disconnect.start()
        layoutProtection.start()
        edid.start()
        configProtection.start(controller: displayController)
        HotkeyController.shared.start()
        UpdaterController.shared.start()
        // Recreate persisted virtual screens at launch (they are process-lifetime).
        if Settings.reconnectVirtualScreensOnWake {
            virtualScreens.reconnectAuto()
        }

        // Tier 5: HTTP control API (app-owned server; Settings read at launch).
        if Settings.httpServerEnabled {
            let handler: (String, String, String?) -> (Int, String) = { [weak self] method, path, body in
                guard let self else { return (500, HTTPJSON.error("app unavailable")) }
                return self.handleHTTP(method: method, path: path, body: body)
            }
            if httpServer.start(port: UInt16(clamping: Settings.httpServerPort), handler: handler) {
                // Prefer the configured port (listener.port may not be
                // populated synchronously); ephemeral ports fall back to it.
                let published = Settings.httpServerPort != 0
                    ? Settings.httpServerPort
                    : Int(self.httpServer.port)
                Settings.httpServerActivePort = published
                log.info("HTTP API listening on 127.0.0.1:\(self.httpServer.port)")
            } else {
                Settings.httpServerActivePort = 0
                log.error("HTTP API failed to start on port \(Settings.httpServerPort)")
            }
        }

        // Tier 5: custom OSD follows display updates (brightness changes from
        // the UI/CLI flow through DisplayController, which posts
        // .fbdDisplayUpdated) — debounced so slider drags coalesce.
        observeOSD()

        if IOAVServiceAPI.isAppleSilicon && IOAVServiceAPI.isRunningUnderRosetta && Settings.showRosettaWarning {
            log.warning("Running under Rosetta — DDC control is unavailable")
            NotificationCenter.default.post(name: .fbdRosettaWarningActive, object: nil)
        }
    }

    // Tier 3/4 controller instances (owned here; UI/CLI create their own for one-shot use).
    let virtualScreens = VirtualScreenController()
    let disconnect = DisconnectController()
    let layoutProtection = LayoutProtectionController()
    let edid = EDIDController()
    let configProtection = ConfigProtectionController()

    // Tier 5 controller instances (owned here; UI/CLI create their own for one-shot use).
    let httpServer = HTTPServer()
    let customOSD = CustomOSD()
    let pip = PipStreamController()
    let nightShift = NightShiftController()
    let trueTone = TrueToneController()

    /// Debounced OSD show (100 ms) so a brightness-slider drag coalesces into
    /// a single HUD update instead of one per notification.
    private var osdDebounceWorkItem: DispatchWorkItem?
    /// Display that changed last (from .fbdDisplayUpdated userInfo).
    private var pendingOSDDisplayID: CGDirectDisplayID?

    // MARK: - URL scheme (fbd://)

    func handle(url: URL) {
        guard url.scheme == "fbd" else {
            log.error("Ignoring non-fbd URL: \(url.absoluteString, privacy: .public)")
            return
        }
        switch url.host {
        case "open":
            openSettingsPanel()
        case "brightness":
            setBrightness(from: url)
        default:
            log.error("Unknown fbd URL: \(url.absoluteString, privacy: .public)")
        }
    }

    private func openSettingsPanel() {
        statusItemController.showPopover()
        NotificationCenter.default.post(name: .fbdOpenSettings, object: nil)
    }

    /// `fbd://brightness/<displayID>/<value 0…1>`
    private func setBrightness(from url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2,
              let id = UInt32(parts[0]),
              let value = Double(parts[1]) else {
            log.error("Malformed fbd://brightness URL: \(url.absoluteString, privacy: .public)")
            return
        }
        guard let display = displayController.display(withID: id) else {
            log.error("fbd://brightness: no display with id \(id)")
            return
        }
        displayController.setBrightness(value, on: display)
        log.info("Set brightness to \(value) for display \(id)")
    }

    // MARK: - Observers

    private func observe(_ name: Notification.Name, handler: @escaping () -> Void) {
        observers.append(
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    handler()
                }
            }
        )
    }

    // MARK: - Custom OSD

    /// Observe .fbdDisplayUpdated (carries the changed display's id) and show
    /// the brightness HUD, debounced to 100 ms.
    private func observeOSD() {
        observers.append(
            NotificationCenter.default.addObserver(forName: .fbdDisplayUpdated, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?["displayID"] as? NSNumber)?.uint32Value
                Task { @MainActor in
                    self?.scheduleOSD(displayID: id)
                }
            }
        )
    }

    /// Debounce .fbdDisplayUpdated into a single HUD show per 100 ms window.
    private func scheduleOSD(displayID: CGDirectDisplayID?) {
        guard Settings.customOSDEnabled else { return }
        pendingOSDDisplayID = displayID
        osdDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.showOSD()
            }
        }
        osdDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    /// Show the HUD for the display that changed (falling back to the first
    /// display when the notification carries no id or the display is gone).
    private func showOSD() {
        guard Settings.customOSDEnabled else { return }
        let display: Display?
        if let id = pendingOSDDisplayID, let found = displayController.display(withID: id) {
            display = found
        } else {
            display = displayController.displays.first
        }
        guard let display, let brightness = display.brightness else { return }
        customOSD.show(icon: "sun.max", value: brightness, displayID: display.id)
    }

    // MARK: - HTTP control API

    /// HTTPServer handler entry point. Runs on the HTTP server's private queue
    /// (off the main actor): parsing is pure, then the main-actor routing is
    /// awaited with a semaphore so the synchronous handler API still replies.
    nonisolated private func handleHTTP(method: String, path: String, body: String?) -> (Int, String) {
        let semaphore = DispatchSemaphore(value: 0)
        var response: (Int, String) = (500, HTTPJSON.error("internal error"))
        Task { @MainActor [weak self] in
            guard let self else {
                response = (500, HTTPJSON.error("app unavailable"))
                semaphore.signal()
                return
            }
            response = self.routeHTTP(method: method, path: path, body: body)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            return (503, #"{"error":"main actor busy"}"#)
        }
        return response
    }

    /// Route an HTTP control-API request to the right endpoint.
    @MainActor private func routeHTTP(method: String, path: String, body: String?) -> (Int, String) {
        // The API is read/write over GET and POST only.
        guard method == "GET" || method == "POST" else {
            return (405, HTTPJSON.error("method not allowed"))
        }
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2, components[0] == "api" else {
            return (404, HTTPJSON.error("not found"))
        }
        switch components[1] {
        case "displays":
            return routeDisplays(method: method, components: components, body: body)
        case "virtual":
            return routeVirtual(method: method, components: components, body: body)
        default:
            return (404, HTTPJSON.error("not found"))
        }
    }

    /// GET /api/displays, GET /api/displays/<id>, POST /api/displays/<id>/<action>.
    @MainActor private func routeDisplays(method: String, components: [String], body: String?) -> (Int, String) {
        if components.count == 2, method == "GET" {
            let list = displayController.displays.map { HTTPJSON.display($0) }
            return (200, HTTPJSON.encode(["displays": list]))
        }
        if components.count == 3, method == "GET" {
            guard let id = HTTPJSON.parseDisplayID(components[2]),
                  let display = displayController.display(withID: id) else {
                return (404, HTTPJSON.error("display not found"))
            }
            var info = HTTPJSON.display(display)
            // Live brightness when the model value is stale (nothing read it yet).
            if info["brightness"] == nil, let value = displayController.getBrightness(for: display) {
                info["brightness"] = value
            }
            info["modes"] = display.modes.map { HTTPJSON.mode($0) }
            return (200, HTTPJSON.encode(info))
        }
        if components.count == 4, method == "GET" {
            // GET /api/displays/<id>/controls | caps
            guard let id = HTTPJSON.parseDisplayID(components[2]),
                  let display = displayController.display(withID: id) else {
                return (404, HTTPJSON.error("display not found"))
            }
            return readDisplayInfo(components[3], for: display)
        }
        if components.count == 4, method == "POST" {
            guard let id = HTTPJSON.parseDisplayID(components[2]),
                  let display = displayController.display(withID: id) else {
                return (404, HTTPJSON.error("display not found"))
            }
            return applyDisplayAction(components[3], to: display, body: body)
        }
        return (404, HTTPJSON.error("not found"))
    }

    /// GET /api/displays/<id>/controls — live DDC reads (contrast/volume/mute/input).
    /// GET /api/displays/<id>/caps — capabilities string.
    @MainActor private func readDisplayInfo(_ what: String, for display: Display) -> (Int, String) {
        // Share DisplayController's DDC instance (single AVService cache and
        // cooldown across CLI/hotkey/UI paths).
        let ddc = DisplayController.shared.ddc
        switch what {
        case "controls":
            var controls: [String: Any] = [:]
            if let value = ddc.getFeature(.contrast, for: display) { controls["contrast"] = value }
            if let value = ddc.getFeature(.volume, for: display) { controls["volume"] = value }
            if let value = ddc.getFeature(.mute, for: display) { controls["muted"] = value > 0 }
            if let value = ddc.getFeature(.inputSource, for: display) { controls["inputSource"] = value }
            return (200, HTTPJSON.encode(["displayID": display.id, "controls": controls]))
        case "caps":
            if let caps = ddc.readCapabilities(for: display) {
                return (200, HTTPJSON.encode(["displayID": display.id, "raw": caps.raw, "mccsVersion": caps.mccsVersion, "vcp": caps.vcpCodes.sorted().map { String(format: "0x%02X", $0) }]))
            }
            return (404, HTTPJSON.error("no capabilities for display"))
        default:
            return (404, HTTPJSON.error("unknown display info '\(what)'"))
        }
    }

    /// POST /api/displays/<id>/brightness|volume|mute|input|mode|xdr.
    @MainActor private func applyDisplayAction(_ action: String, to display: Display, body: String?) -> (Int, String) {
        guard let body, let object = HTTPJSON.parse(body) else {
            return (400, HTTPJSON.error("invalid JSON body"))
        }
        switch action {
        case "contrast":
            guard let value = object["value"] as? Double, (0...1).contains(value) else {
                return (400, HTTPJSON.error("value must be a number between 0 and 1"))
            }
            guard displayController.setContrast(value, on: display) else {
                return (500, HTTPJSON.error("write not accepted"))
            }
            return (200, HTTPJSON.encode(["ok": true]))
        case "brightness":
            guard let value = object["value"] as? Double, (0...1).contains(value) else {
                return (400, HTTPJSON.error("value must be a number between 0 and 1"))
            }
            guard displayController.setBrightness(value, on: display) else {
                return (500, HTTPJSON.error("no control path for display"))
            }
            return (200, HTTPJSON.encode(["ok": true]))
        case "volume":
            guard let value = object["value"] as? Double, (0...1).contains(value) else {
                return (400, HTTPJSON.error("value must be a number between 0 and 1"))
            }
            guard displayController.setVolume(value, on: display) else {
                return (500, HTTPJSON.error("write not accepted"))
            }
            return (200, HTTPJSON.encode(["ok": true]))
        case "mute":
            guard let muted = object["muted"] as? Bool else {
                return (400, HTTPJSON.error("muted must be a boolean"))
            }
            guard displayController.setMuted(muted, on: display) else {
                return (500, HTTPJSON.error("write not accepted"))
            }
            return (200, HTTPJSON.encode(["ok": true]))
        case "input":
            guard let source = (object["source"] as? NSNumber).flatMap({ UInt16(exactly: $0.uint32Value) }) else {
                return (400, HTTPJSON.error("source must be a number"))
            }
            guard displayController.setInputSource(source, on: display) else {
                return (500, HTTPJSON.error("write not accepted"))
            }
            return (200, HTTPJSON.encode(["ok": true]))
        case "mode":
            guard let width = (object["width"] as? NSNumber)?.int32Value,
                  let height = (object["height"] as? NSNumber)?.int32Value else {
                return (400, HTTPJSON.error("width and height are required"))
            }
            let hz = (object["hz"] as? NSNumber)?.doubleValue
            guard let mode = HTTPJSON.bestMode(matchingWidth: width, height: height, hz: hz, in: display) else {
                return (404, HTTPJSON.error("no matching mode"))
            }
            displayController.applyMode(mode, to: display)
            return (200, HTTPJSON.encode(["ok": true, "mode": mode.key]))
        case "xdr":
            if let nits = (object["nits"] as? NSNumber)?.intValue, nits > 0 {
                guard displayController.setXDRUpscaleTarget(nits, on: display) else {
                    return (500, HTTPJSON.error("XDR upscaling failed"))
                }
                return (200, HTTPJSON.encode(["ok": true, "nits": nits]))
            }
            if let enabled = object["enabled"] as? Bool, !enabled {
                guard displayController.disableXDRUpscaling(on: display) else {
                    return (500, HTTPJSON.error("failed to disable XDR upscaling"))
                }
                return (200, HTTPJSON.encode(["ok": true]))
            }
            return (400, HTTPJSON.error("expected {\"nits\": n} or {\"enabled\": false}"))
        default:
            return (404, HTTPJSON.error("unknown action '\(action)'"))
        }
    }

    /// POST /api/virtual/create, POST /api/virtual/destroy.
    @MainActor private func routeVirtual(method: String, components: [String], body: String?) -> (Int, String) {
        if components.count == 2, method == "GET" {
            let controller = VirtualScreenController.shared
            let screens = controller.screens.map { ["id": $0.id, "name": $0.config.name, "displayID": $0.displayID] }
            let configs = controller.configs.map { ["id": $0.id, "name": $0.name] }
            return (200, HTTPJSON.encode(["screens": screens, "configs": configs]))
        }
        guard components.count == 3, method == "POST" else {
            return (404, HTTPJSON.error("not found"))
        }
        guard let body, let object = HTTPJSON.parse(body) else {
            return (400, HTTPJSON.error("invalid JSON body"))
        }
        let controller = VirtualScreenController.shared
        switch components[2] {
        case "create":
            guard let name = object["name"] as? String, !name.isEmpty,
                  let width = (object["width"] as? NSNumber).flatMap({ UInt32(exactly: $0.uint32Value) }), width > 0,
                  let height = (object["height"] as? NSNumber).flatMap({ UInt32(exactly: $0.uint32Value) }), height > 0 else {
                return (400, HTTPJSON.error("name, width, and height are required"))
            }
            guard controller.isAvailable else {
                return (500, HTTPJSON.error("virtual displays unavailable on this macOS"))
            }
            let hz = (object["hz"] as? NSNumber)?.doubleValue ?? 60
            let config = VirtualScreenConfig(
                name: name,
                width: width,
                height: height,
                refreshRate: hz,
                isHDR: false,
                autoConnect: true
            )
            guard controller.create(config) else {
                return (500, HTTPJSON.error("failed to create virtual display"))
            }
            let displayID = controller.displayID(for: config.id) ?? 0
            return (201, HTTPJSON.encode(["ok": true, "id": config.id, "displayID": displayID]))
        case "destroy":
            guard let id = object["id"] as? String, !id.isEmpty else {
                return (400, HTTPJSON.error("id is required"))
            }
            guard controller.destroy(id: id) else {
                return (404, HTTPJSON.error("no virtual display '\(id)'"))
            }
            return (200, HTTPJSON.encode(["ok": true]))
        default:
            return (404, HTTPJSON.error("unknown action '\(components[2])'"))
        }
    }
}

// MARK: - HTTP JSON helpers

/// JSON encoding + display serialization for the HTTP control API. A plain
/// (non-isolated) enum so the HTTPServer's off-main queue can use it directly.
private enum HTTPJSON {
    /// Compact JSON string for an HTTP response.
    static func encode(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"error":"encoding failed"}"#
        }
        return String(data: data, encoding: .utf8) ?? #"{"error":"encoding failed"}"#
    }

    static func error(_ message: String) -> String {
        encode(["error": message])
    }

    static func parse(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Parse a display id: plain decimal, or 0x-prefixed hex.
    static func parseDisplayID(_ string: String) -> CGDirectDisplayID? {
        if string.hasPrefix("0x") || string.hasPrefix("0X") {
            return CGDirectDisplayID(string.dropFirst(2), radix: 16)
        }
        return CGDirectDisplayID(string)
    }

    /// JSON object for one display (list + info endpoints).
    static func display(_ display: Display) -> [String: Any] {
        var info: [String: Any] = [
            "id": display.id,
            "name": display.name,
            "builtin": display.isBuiltin,
            "virtual": display.isVirtual,
            "online": display.isOnline,
            "active": display.isActive,
            "ddc": display.ddcAvailable,
            "appleBrightness": display.appleBrightnessAvailable,
            "bounds": [
                "x": display.bounds.origin.x,
                "y": display.bounds.origin.y,
                "width": display.bounds.width,
                "height": display.bounds.height,
            ],
        ]
        if let brightness = display.brightness {
            info["brightness"] = brightness
        }
        if let mode = display.currentMode {
            info["currentMode"] = mode.key
        }
        info["xdrCapable"] = display.isXDRCapable
        info["xdrUpscaled"] = display.isXDRUpscaled
        if let target = display.xdrUpscaleTargetNits {
            info["xdrTargetNits"] = target
        }
        return info
    }

    static func mode(_ mode: DisplayMode) -> [String: Any] {
        [
            "key": mode.key,
            "width": mode.pixelsWide,
            "height": mode.pixelsHigh,
            "hz": mode.refreshRate,
            "hidpi": mode.isHiDPI,
            "safe": mode.isSafe,
        ]
    }

    /// Best matching mode for (width, height, hz): same physical pixels,
    /// nearest refresh rate, HiDPI preferred, then safe. `hz` nil keeps the
    /// display's current refresh rate when possible.
    static func bestMode(matchingWidth width: Int32, height: Int32, hz: Double?, in display: Display) -> DisplayMode? {
        let candidates = display.modes.filter { $0.pixelsWide == width && $0.pixelsHigh == height }
        guard !candidates.isEmpty else { return nil }
        if let hz {
            return candidates.sorted { a, b in
                let distanceA = abs(a.refreshRate - hz)
                let distanceB = abs(b.refreshRate - hz)
                if distanceA != distanceB { return distanceA < distanceB }
                if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
                if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
                return a.isSafe && !b.isSafe
            }.first
        }
        if let current = display.currentMode,
           let sameRate = candidates.first(where: { $0.refreshRate == current.refreshRate }) {
            return sameRate
        }
        return candidates.sorted { a, b in
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
            return a.isSafe && !b.isSafe
        }.first
    }
}

// MARK: - App-level notifications

extension Notification.Name {
    /// Posted when the settings panel should be shown (fbd://open).
    static let fbdOpenSettings = Notification.Name("FBDOpenSettings")
    /// Posted once at startup when DDC is unavailable under Rosetta.
    static let fbdRosettaWarningActive = Notification.Name("FBDRosettaWarningActive")
}
