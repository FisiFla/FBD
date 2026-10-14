import AppKit
import CryptoKit
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
        // Re-apply persisted corner masks now that the display list exists. A
        // radius of 0 spawns nothing, so this is free for untouched displays.
        displayController.restoreCornerRadii()
        // Startup control values (row 9): the default policy does nothing, so this is
        // free for anyone who never changed it.
        displayController.applyStartupControlValuePolicy()
        // The Mac's own output volume (#20): one shared controller so the media
        // keys, the CLI and this HUD all act on the same device handle. Refresh
        // is asynchronous by design, so it does not delay launch.
        SystemVolumeController.shared.onChange = { [weak self] in
            self?.showSystemVolumeOSD()
        }
        SystemVolumeController.shared.refresh()
        statusItemController.install()

        // Keep the Mac awake if that is what was asked for last time. Deliberately
        // outside the safe-mode gate below: that gate exists to escape a bad
        // *display* configuration, and a power assertion is not a state anyone
        // needs escaping from.
        KeepAwakeController.shared.applyStoredPreference()

        // Tier 3 controllers: virtual screens, soft disconnect, layout protection.
        virtualScreens.start()
        disconnect.start()
        layoutProtection.start()
        // Startup safe mode (BetterDisplay parity): when the user held Shift at
        // launch — or set FBD_SAFE_MODE — do NOT re-apply stored configuration
        // for the session. A bad custom EDID override or a stored
        // config-protection blob is exactly what the user is escaping, so the
        // EDID lifecycle hook and the configuration-protection restore observer
        // stay off. Fail-closed: this only ever suppresses an apply.
        if SafeMode.shouldApplyStoredState(
            modifierFlags: NSEvent.modifierFlags.rawValue,
            readFromEnvironment: ProcessInfo.processInfo.environment
        ) {
            edid.start()
            configProtection.start(controller: displayController)
        } else {
            log.notice("safe mode: skipping stored EDID override and configuration-protection restore")
            FBDNotice.shared.report("Safe mode: saved EDID override and configuration-protection restore are off for this session")
        }
        automation.start(controller: displayController)
        // Notification permission is asked for only when a stored rule needs it, so
        // a user who never configures one is never prompted. Without this the
        // notification action would be inert: a request added while authorisation is
        // undetermined shows nothing.
        if automation.hasNotificationRule {
            UserNotificationDeliverer.requestAuthorization()
        }

        applyDockPolicy()
        // Lock dim: lower brightness while the screen is locked or the screensaver
        // is up, and restore it on unlock. Started unconditionally — the policy is
        // read per event, so a disabled policy is a no-op rather than a dead
        // observer, and the state machine always restores what it recorded.
        lockDim.start()
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

    /// Dock visibility. A menu-bar app runs as an accessory — no Dock icon and no
    /// app-switcher entry — unless the user asks for one, or asks for one briefly
    /// at launch so the app can be found in the Dock just after it opens.
    ///
    /// `main.swift` sets `.accessory` before the app runs; this is what can change
    /// it afterwards, and it re-checks the permanent setting before dropping back,
    /// so a brief icon cannot undo a deliberate one.
    private func applyDockPolicy() {
        if Settings.showDockIcon {
            NSApp.setActivationPolicy(.regular)
            return
        }
        guard Settings.briefDockIconAtStartup else { return }
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Settings.showDockIcon else { return }
            NSApp.setActivationPolicy(.accessory)
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
    let lockDim = LockDimController()
    /// Per-display event automation. Lives here so one instance owns the
    /// observers; the CLI creates its own for one-shot rule edits.
    let automation = DisplayAutomationController()

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
        case "close":
            // Deterministic panel teardown, so a script or a test never has to
            // guess with synthetic Escape keypresses or go hunting for the close
            // button. `fbd://open` is its counterpart.
            statusItemController.closePanel()
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

    /// Constant-time-ish token comparison matching HTTPRouter's.
    private static func tokenMatches(_ provided: String?, _ expected: String) -> Bool {
        guard let provided, !provided.isEmpty else { return false }
        let providedDigest = SHA256.hash(data: Data(provided.utf8))
        let expectedDigest = SHA256.hash(data: Data(expected.utf8))
        return providedDigest == expectedDigest
    }

    private func setBrightness(from url: URL) {
        // Brightness writes through the URL scheme require the same API token
        // as the HTTP surface, so a local drive-by cannot change displays
        // without the user's consent. Supply it as ?token=<httpAPIToken>.
        let suppliedToken = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "token" })?.value
        guard Self.tokenMatches(suppliedToken, Settings.httpAPIToken) else {
            log.error("fbd://brightness: missing or invalid token")
            return
        }
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
    private func showOSD() {        guard Settings.customOSDEnabled else { return }
        let display: Display?
        if let id = pendingOSDDisplayID, let found = displayController.display(withID: id) {
            display = found
        } else {
            display = displayController.displays.first
        }
        guard let display, let brightness = display.brightness else { return }
        customOSD.show(icon: "sun.max", value: brightness, displayID: display.id)
    }

    /// HUD for the Mac's own output volume (#20).
    ///
    /// Shown with no `displayID`, so it appears on whichever display the pointer
    /// is on — the same place macOS puts its own volume HUD. A mute toggle shows
    /// the slashed speaker rather than a volume of zero, so the two states are
    /// distinguishable at a glance.
    private func showSystemVolumeOSD() {
        guard Settings.customOSDEnabled else { return }
        let volume = SystemVolumeController.shared
        customOSD.show(
            icon: volume.isMuted ? "speaker.slash" : "speaker.wave.2",
            value: volume.volume ?? 0
        )
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
