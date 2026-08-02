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
            let handler: (String, String, String?, [String: String]) -> (Int, String) = { [weak self] method, path, body, headers in
                guard let self else { return (500, HTTPJSON.error("app unavailable")) }
                return self.handleHTTP(method: method, path: path, body: body, headers: headers)
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
        statusItemController.showPanel()
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
    nonisolated private func handleHTTP(method: String, path: String, body: String?, headers: [String: String]) -> (Int, String) {
        let semaphore = DispatchSemaphore(value: 0)
        var response: (Int, String) = (500, HTTPJSON.error("internal error"))
        Task { @MainActor [weak self] in
            guard let self else {
                response = (500, HTTPJSON.error("app unavailable"))
                semaphore.signal()
                return
            }
            response = self.routeHTTP(method: method, path: path, body: body, headers: headers)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            return (503, #"{"error":"main actor busy"}"#)
        }
        return response
    }

    /// Pure routing (auth, method, path, body validation) lives in
    /// HTTPRouter (FBDCore, unit-tested); this method only executes the
    /// typed route against the controllers.
    @MainActor private func routeHTTP(method: String, path: String, body: String?, headers: [String: String]) -> (Int, String) {
        switch HTTPRouter.route(
            method: method,
            path: path,
            body: body,
            headers: headers,
            expectedToken: Settings.httpAPIToken
        ) {
        case .error(let status, let message):
            return (status, HTTPJSON.error(message))
        case .route(let route):
            return execute(route)
        }
    }

    /// Execute a validated HTTP route. All parseable failures were already
    /// rejected by HTTPRouter; failures here are runtime/controller-level.
    @MainActor private func execute(_ route: HTTPRoute) -> (Int, String) {
        switch route {
        case .listDisplays:
            let list = displayController.displays.map { HTTPJSON.display($0) }
            return (200, HTTPJSON.encode(["displays": list]))
        case .displayInfo(let id):
            guard let display = displayController.display(withID: id) else {
                return (404, HTTPJSON.error("display not found"))
            }
            var info = HTTPJSON.display(display)
            // Live brightness when the model value is stale (nothing read it yet).
            if info["brightness"] == nil, let value = displayController.getBrightness(for: display) {
                info["brightness"] = value
            }
            info["modes"] = display.modes.map { HTTPJSON.mode($0) }
            return (200, HTTPJSON.encode(info))
        case .displayControls(let id, let what):
            guard let display = displayController.display(withID: id) else {
                return (404, HTTPJSON.error("display not found"))
            }
            switch what {
            case "controls":
                let controls = displayController.readDDCControls(for: display)
                let json: [String: Any] = [
                    "contrast": controls.contrast as Any? ?? NSNull(),
                    "volume": controls.volume as Any? ?? NSNull(),
                    "muted": controls.muted as Any? ?? NSNull(),
                    "inputSource": controls.inputSource as Any? ?? NSNull(),
                ]
                return (200, HTTPJSON.encode(["displayID": display.id, "controls": json]))
            default: // "caps"
                if let caps = displayController.readDDCCapabilities(for: display) {
                    return (200, HTTPJSON.encode(["displayID": display.id, "raw": caps.raw, "mccsVersion": caps.mccsVersion, "vcp": caps.vcpCodes.sorted().map { String(format: "0x%02X", $0) }]))
                }
                return (404, HTTPJSON.error("no capabilities for display"))
            }
        case .displayAction(let id, let action):
            guard let display = displayController.display(withID: id) else {
                return (404, HTTPJSON.error("display not found"))
            }
            switch action {
            case .contrast(let value):
                guard displayController.setContrast(value, on: display) else { return (500, HTTPJSON.error("write not accepted")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .brightness(let value):
                guard displayController.setBrightness(value, on: display) else { return (500, HTTPJSON.error("no control path for display")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .volume(let value):
                guard displayController.setVolume(value, on: display) else { return (500, HTTPJSON.error("write not accepted")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .mute(let muted):
                guard displayController.setMuted(muted, on: display) else { return (500, HTTPJSON.error("write not accepted")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .input(let source):
                guard displayController.setInputSource(source, on: display) else { return (500, HTTPJSON.error("write not accepted")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .mode(let width, let height, let hz):
                guard let mode = HTTPJSON.bestMode(matchingWidth: width, height: height, hz: hz, in: display) else {
                    return (404, HTTPJSON.error("no matching mode"))
                }
                displayController.applyMode(mode, to: display)
                return (200, HTTPJSON.encode(["ok": true, "mode": mode.key]))
            case .xdr(let nits):
                guard displayController.setXDRUpscaleTarget(nits, on: display) else { return (500, HTTPJSON.error("XDR upscaling failed")) }
                return (200, HTTPJSON.encode(["ok": true, "nits": nits]))
            case .xdrDisable:
                guard displayController.disableXDRUpscaling(on: display) else { return (500, HTTPJSON.error("failed to disable XDR upscaling")) }
                return (200, HTTPJSON.encode(["ok": true]))
            }
        case .virtualList:
            let controller = VirtualScreenController.shared
            let screens = controller.screens.map { ["id": $0.id, "name": $0.config.name, "displayID": $0.displayID] }
            let configs = controller.configs.map { ["id": $0.id, "name": $0.name] }
            return (200, HTTPJSON.encode(["screens": screens, "configs": configs]))
        case .virtualCreate(let request):
            let controller = VirtualScreenController.shared
            guard controller.isAvailable else {
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
            guard controller.create(config) else {
                return (500, HTTPJSON.error("failed to create virtual display"))
            }
            let displayID = controller.displayID(for: config.id) ?? 0
            return (201, HTTPJSON.encode(["ok": true, "id": config.id, "displayID": displayID]))
        case .virtualDestroy(let id):
            let controller = VirtualScreenController.shared
            guard controller.destroy(id: id) else {
                return (404, HTTPJSON.error("no virtual display '\(id)'"))
            }
            return (200, HTTPJSON.encode(["ok": true]))
        }
    }
}

// MARK: - App-level notifications

extension Notification.Name {
    /// Posted when the settings panel should be shown (fbd://open).
    static let fbdOpenSettings = Notification.Name("FBDOpenSettings")
    static let fbdPanelCloseRequested = Notification.Name("FBDPanelCloseRequested")
    /// Posted once at startup when DDC is unavailable under Rosetta.
    static let fbdRosettaWarningActive = Notification.Name("FBDRosettaWarningActive")
}
