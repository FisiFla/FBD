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
    /// Keeps the SIGTERM dispatch source alive for the app's lifetime.
    private var sigtermSource: DispatchSourceSignal?

    init() {
        statusItemController = StatusItemController()
    }

    func start() {
        installSigtermHandler()
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

        // Tier 5: HTTP control API. The server reconciles live against
        // Settings, so `fbdcli http on/off` applies without an app restart.
        reconcileHTTPServer()
        // Same-process writes arrive instantly via the notification;
        // cross-process writes (the CLI) are covered by a light poll.
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileHTTPServer() }
        })
        let pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileHTTPServer() }
        }
        httpReconcileTimer = pollTimer

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
    // Single shared instance (the UI and HTTP paths use the same one) so
    // screens/configs never diverge between callers.
    let virtualScreens = VirtualScreenController.shared
    let disconnect = DisconnectController()
    let layoutProtection = LayoutProtectionController()
    let edid = EDIDController()
    let configProtection = ConfigProtectionController()

    // Tier 5 controller instances (owned here; UI/CLI create their own for one-shot use).
    let httpServer = HTTPServer()
    /// Last reconciled HTTP state (avoids redundant restarts on unrelated
    /// defaults changes).
    private var httpLastEnabled = false
    private var httpLastPort = 0
    private var httpReconcileTimer: Timer?
    let customOSD = CustomOSD()
    let pip = PipStreamController()
    let nightShift = NightShiftController()
    let trueTone = TrueToneController()

    /// Debounced OSD show (100 ms) so a brightness-slider drag coalesces into
    /// a single HUD update instead of one per notification.
    private var osdDebounceWorkItem: DispatchWorkItem?
    /// Display that changed last (from .fbdDisplayUpdated userInfo).
    private var pendingOSDDisplayID: CGDirectDisplayID?

    /// Start/stop/restart the HTTP server to match Settings. A no-op unless
    /// the enabled flag or the port actually changed.
    @MainActor private func reconcileHTTPServer() {
        let enabled = Settings.httpServerEnabled
        let port = Settings.httpServerPort
        guard enabled != httpLastEnabled || port != httpLastPort else { return }
        httpLastEnabled = enabled
        httpLastPort = port

        if !enabled {
            if httpServer.isRunning {
                httpServer.stop()
                Settings.httpServerActivePort = 0
                log.info("HTTP API stopped")
            }
            return
        }

        // Enabled: (re)start — a port change while running restarts the
        // listener on the new port.
        let handler: (String, String, String?, [String: String]) -> (Int, String) = { [weak self] method, path, body, headers in
            guard let self else { return (500, HTTPJSON.error("app unavailable")) }
            return self.handleHTTP(method: method, path: path, body: body, headers: headers)
        }
        if httpServer.start(port: UInt16(clamping: port), handler: handler) {
            // Prefer the configured port (listener.port may not be
            // populated synchronously); ephemeral ports fall back to it.
            let published = port != 0 ? port : Int(self.httpServer.port)
            Settings.httpServerActivePort = published
            log.info("HTTP API listening on 127.0.0.1:\(self.httpServer.port)")
        } else {
            Settings.httpServerActivePort = 0
            log.error("HTTP API failed to start on port \(port)")
        }
    }

    /// Route SIGTERM (`kill`, session end, tools) through NSApp.terminate so
    /// AppKit cleanup runs — most importantly the willTerminate observers
    /// (EDID factory restore on quit when enabled).
    private func installSigtermHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApp.terminate(nil)
        }
        source.resume()
        sigtermSource = source
    }

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
        // The whole API surface lives in FBDCore (HTTPExecutor) behind the
        // DisplayControlling seam — testable with a fake; AppCore only
        // supplies the adapter and the app version.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return HTTPExecutor.execute(route, controller: displayController, version: version)
    }
}

// MARK: - App-level notifications

extension Notification.Name {
    /// Posted when the settings panel should be shown (fbd://open).
    static let fbdOpenSettings = Notification.Name("FBDOpenSettings")
    /// Posted by the Settings back button when leaving the settings page.
    static let fbdSettingsClosed = Notification.Name("FBDSettingsClosed")
    static let fbdPanelCloseRequested = Notification.Name("FBDPanelCloseRequested")
    /// Posted once at startup when DDC is unavailable under Rosetta.
    static let fbdRosettaWarningActive = Notification.Name("FBDRosettaWarningActive")
}
