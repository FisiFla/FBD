import AppKit
import CoreGraphics
import Darwin
import Foundation
import os

/// A connected virtual screen instance.
public struct VirtualScreenInstance: Identifiable, Equatable {
    public let id: String            // matches VirtualScreenConfig.id
    public let displayID: CGDirectDisplayID
    public let config: VirtualScreenConfig

    public init(id: String, displayID: CGDirectDisplayID, config: VirtualScreenConfig) {
        self.id = id
        self.displayID = displayID
        self.config = config
    }
}

/// Owns virtual screens: create/connect via the SLVirtualDisplay API
/// (macOS 26+, SkyLight — live-verified: create → applySettings → appears in
/// CGGetActiveDisplayList → destroy → removed), persists configurations, and
/// reconnects after wake/lock transitions.
///
/// The legacy CGVirtualDisplay path (macOS 13–15, VirtualDisplay.framework) is
/// probed via dlopen so `isAvailable` is truthful, but creating a screen
/// currently uses the SL path only — on 13–15 `create` degrades to a logged
/// failure instead of crashing. The CG path would be layered in here.
///
/// Plain class; call on the main thread from DisplayController/UI. Wake/lock
/// notification callbacks hop to the main queue internally.
public final class VirtualScreenController {
    /// Process-wide instance. IMPORTANT: virtual displays are process-lifetime
    /// objects — they exist only while the owning process runs. Use `shared`
    /// (owned by the app) for persistent screens; CLI-created screens die with
    /// the CLI process.
    public static let shared = VirtualScreenController()

    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "VirtualScreenController")

    /// Active screens (connected), in creation order.
    public private(set) var screens: [VirtualScreenInstance] = []

    /// True when ANY virtual display path is available (SL on macOS 26+, CG on 13–15).
    public var isAvailable: Bool {
        if VirtualDisplayAPI.isAvailable { return true }
        return Self.isCGPathAvailable
    }

    /// Persisted configurations (connected + pending).
    public var configs: [VirtualScreenConfig]

    /// SL handles backing each active screen, keyed by config id.
    private var handles: [String: VirtualDisplayAPI.VirtualDisplayHandle] = [:]

    private var hasRegistered = false
    private var observers: [NSObjectProtocol] = []

    public init() {
        configs = Settings.loadVirtualScreens()
    }

    // MARK: - Create / destroy

    /// Create + connect a virtual screen from a config. Returns false on failure.
    @discardableResult
    public func create(_ config: VirtualScreenConfig) -> Bool {
        // Defensive: if the id is somehow already active (UI normally calls
        // create only for new ids), drop the old instance first so the handle
        // is not leaked.
        if isActive(id: config.id) {
            _ = destroy(id: config.id)
        }
        guard VirtualDisplayAPI.isAvailable else {
            log.warning("create(\(config.name)) failed: SLVirtualDisplay unavailable (CG path on 13–15 not yet implemented)")
            return false
        }
        guard let handle = VirtualDisplayAPI.create(name: config.name, maxPixels: (config.width, config.height)) else {
            log.warning("create(\(config.name)) failed: SLVirtualDisplay creation returned nil")
            return false
        }
        guard let mode = VirtualDisplayAPI.makeMode(
            pixels: (config.width, config.height),
            points: (config.width, config.height),
            refreshRate: config.refreshRate
        ) else {
            handle.destroy()
            log.warning("create(\(config.name)) failed: could not build mode")
            return false
        }
        // HDR is best-effort: set the mode's EOTF via KVC (4 = HDR, 0 = SDR).
        // The call is non-throwing; an ignored/unknown key falls back to SDR.
        mode.setValue(config.isHDR ? 4 : 0, forKey: "eotf")
        if config.isHDR {
            log.debug("HDR requested for \(config.name); eotf set best-effort")
        }
        guard let settings = VirtualDisplayAPI.makeSettings(native: mode) else {
            handle.destroy()
            log.warning("create(\(config.name)) failed: could not build settings")
            return false
        }
        guard handle.apply(settings: settings) else {
            handle.destroy()
            log.warning("create(\(config.name)) failed: applySettings returned false")
            return false
        }
        SkyLightAPI.detectDisplays()

        // Upsert the active instance and its persisted config.
        let instance = VirtualScreenInstance(id: config.id, displayID: handle.displayID, config: config)
        screens.removeAll { $0.id == config.id }
        screens.append(instance)
        handles[config.id] = handle
        configs.removeAll { $0.id == config.id }
        configs.append(config)
        Settings.saveVirtualScreens(configs)
        NotificationCenter.default.post(name: .fbdDisplaysChanged, object: nil)
        log.debug("virtual screen connected: \(config.name) (display \(handle.displayID))")
        return true
    }

    /// Disconnect + forget (removes from persistence).
    @discardableResult
    public func destroy(id: String) -> Bool {
        var destroyed = false
        if let index = screens.firstIndex(where: { $0.id == id }) {
            let screen = screens[index]
            handles[id]?.destroy()
            handles[id] = nil
            screens.remove(at: index)
            log.debug("virtual screen destroyed: \(screen.config.name) (display \(screen.displayID))")
            destroyed = true
        } else {
            log.debug("destroy(\(id)): no active screen with that id — removing persisted config only")
        }
        // Always remove the persisted config, even when no live instance exists
        // (e.g. the owning process exited and the display vanished with it).
        let wasPersisted = configs.contains { $0.id == id }
        configs.removeAll { $0.id == id }
        Settings.saveVirtualScreens(configs)
        if destroyed || wasPersisted {
            SkyLightAPI.detectDisplays()
            NotificationCenter.default.post(name: .fbdDisplaysChanged, object: nil)
            return true
        }
        log.warning("destroy(\(id)): unknown config id")
        return false
    }

    /// Disconnect all active screens (keeps persistence).
    public func disconnectAll() {
        guard !screens.isEmpty else { return }
        let count = screens.count
        for screen in screens {
            handles[screen.id]?.destroy()
            handles[screen.id] = nil
        }
        SkyLightAPI.detectDisplays()
        screens.removeAll()
        NotificationCenter.default.post(name: .fbdDisplaysChanged, object: nil)
        log.debug("disconnected \(count) virtual screen(s)")
    }

    // MARK: - Reconnect

    /// Reconnect a persisted config that is not active.
    @discardableResult
    public func reconnect(id: String) -> Bool {
        guard let config = configs.first(where: { $0.id == id }) else {
            log.warning("reconnect(\(id)) failed: no persisted config with that id")
            return false
        }
        guard !isActive(id: id) else {
            log.debug("reconnect(\(id)) skipped: already active")
            return false
        }
        // `create` reuses the persisted config's id.
        return create(config)
    }

    /// Reconnect all configs with autoConnect == true (used on wake/app start).
    public func reconnectAuto() {
        var reconnected = 0
        for config in configs where config.autoConnect && !isActive(id: config.id) {
            if create(config) { reconnected += 1 }
        }
        if reconnected > 0 {
            log.debug("reconnected \(reconnected) virtual screen(s)")
        }
    }

    // MARK: - Queries

    public func isActive(id: String) -> Bool {
        screens.contains { $0.id == id }
    }

    public func displayID(for id: String) -> CGDirectDisplayID? {
        screens.first { $0.id == id }?.displayID
    }

    // MARK: - Lifecycle

    /// Called by DisplayController to re-sync after display changes.
    /// No-op: active screens are tracked by this controller, and SL display
    /// IDs are stable for the lifetime of the handle — re-matching
    /// CGGetActiveDisplayList is not needed here (DisplayController owns the
    /// live display list).
    public func refresh() {
        // Intentionally empty (see doc comment).
    }

    /// Wake/lock observation: reconnectAuto on wake (Settings.reconnectVirtualScreensOnWake),
    /// disconnectAll on lock (Settings.disconnectVirtualScreensOnLock).
    public func start() {
        guard !hasRegistered else { return }
        hasRegistered = true

        let center = NSWorkspace.shared.notificationCenter

        // Wake: reconnect auto-connect screens.
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, Settings.reconnectVirtualScreensOnWake else { return }
                self.reconnectAuto()
            }
        })

        // Screen parameters changed (resolution/layout): re-sync (no-op today).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        })

        // Session notifications (macOS 14+). Lock-disconnect is best-effort:
        // sessionDidResignActive also fires on logout, but disconnectAll keeps
        // persistence, so the screens simply reconnect on the next session.
        if #available(macOS 14, *) {
            observers.append(center.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: nil
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, Settings.reconnectVirtualScreensOnWake else { return }
                    self.reconnectAuto()
                }
            })
            observers.append(center.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, Settings.disconnectVirtualScreensOnLock else { return }
                    self.disconnectAll()
                }
            })
        }
    }
}

// MARK: - CG path probe (macOS 13–15)

private extension VirtualScreenController {
    /// The VirtualDisplay.framework exists on macOS 13–15 only; on macOS 26+
    /// the path is gone, so a lazy dlopen probe is a truthful availability
    /// check for the legacy CG path. Never closed (process-lifetime probe).
    static let isCGPathAvailable: Bool = {
        dlopen("/System/Library/Frameworks/VirtualDisplay.framework/VirtualDisplay", RTLD_LAZY | RTLD_LOCAL) != nil
    }()
}
