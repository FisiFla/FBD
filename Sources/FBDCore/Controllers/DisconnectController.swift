import CoreGraphics
import Foundation
import os

/// Soft disconnect / reconnect of displays (CGSConfigureDisplayEnabled).
///
/// Disabling a display removes it from the active layout — the screen goes
/// black until it is re-enabled. Automatic use is restricted to the built-in
/// display when `Settings.autoDisconnectBuiltInOnExternal` is on; every other
/// call is user-initiated.
///
/// Plain class; the `.fbdDisplaysChanged` callback hops to the main queue.
public final class DisconnectController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "DisconnectController")

    private var hasRegistered = false
    private var observer: NSObjectProtocol?
    private static let disabledByUsKey = "builtInDisabledByUs"

    private let defaults: UserDefaults

    /// True while the built-in display is disabled by us (auto-disconnect active). Persisted:
    /// the disable is committed `.permanently`, so a quit or crash while it is set must still
    /// bring the built-in back on the next launch.
    var builtInDisabledByUs: Bool {
        get { defaults.bool(forKey: Self.disabledByUsKey) }
        set { defaults.set(newValue, forKey: Self.disabledByUsKey) }
    }

    public init(defaults: UserDefaults = Settings.defaults) {
        self.defaults = defaults
    }

    /// Disable or re-enable a display in the layout. Black screen on disable —
    /// only auto-used for external displays / user-initiated actions.
    ///
    /// Disconnecting a built-in display is refused on Macs that may not bring it
    /// back without a reboot (base-M3 MacBook Air / entry-level M3 MacBook Pro)
    /// unless the user has set the explicit override — see `BuiltInDisconnectGuard`.
    @discardableResult
    public func setEnabled(_ enabled: Bool, displayID: CGDirectDisplayID) -> Bool {
        if !enabled, CGDisplayIsBuiltin(displayID) != 0, !BuiltInDisconnectGuard.builtInDisconnectAllowed {
            log.error("refusing to disconnect built-in display \(displayID): this Mac's built-in display may not reconnect without a reboot (override in Settings)")
            return false
        }
        do {
            try CGSAPI.setEnabled(enabled, displayID: displayID)
        } catch {
            log.warning("setEnabled(\(enabled)) failed for \(displayID): \(error.localizedDescription)")
            return false
        }
        SkyLightAPI.detectDisplays()
        NotificationCenter.default.post(name: .fbdDisplaysChanged, object: nil)
        log.debug("display \(displayID) \(enabled ? "enabled" : "disabled")")
        return true
    }

    /// Apply a connection plan (see `ConnectionPlanner`) through the guarded
    /// `setEnabled` chokepoint — the single place a disconnect is performed.
    ///
    /// Every step is attempted in order; a step the built-in-disconnect guard
    /// (or the OS) refuses is *skipped*, never forced, so a safety refusal
    /// cannot stall the remaining steps. Returns the number of steps that
    /// succeeded. Never throws; an unknown or unconnected display degrades to a
    /// refused step rather than a crash.
    @discardableResult
    public func apply(_ steps: [ConnectionStep]) -> Int {
        var applied = 0
        for step in steps {
            if setEnabled(step.enable, displayID: step.displayID) {
                applied += 1
            } else {
                log.debug("connection step skipped: \(step.reason)")
            }
        }
        return applied
    }

    /// Observe display topology; when Settings.autoDisconnectBuiltInOnExternal is on
    /// and an external (non-builtin) display becomes active, disable the built-in.
    public func start() {
        guard !hasRegistered else { return }
        hasRegistered = true
        observer = NotificationCenter.default.addObserver(
            forName: .fbdDisplaysChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evaluateAutoDisconnect()
        }
        // A flag left set by a previous run: re-enable the built-in if its reason has gone.
        if builtInDisabledByUs { evaluateAutoDisconnect() }
    }

    /// React to topology changes. Only acts when the setting is on, and only on
    /// state transitions (built-in active + external appeared → disable; built-in
    /// disabled by us + no external → re-enable). The `builtInDisabledByUs` flag
    /// plus the active/online checks keep this from looping on the
    /// `.fbdDisplaysChanged` notifications our own calls post.
    private func evaluateAutoDisconnect() {
        let activeIDs = activeDisplayIDs()
        let externalActive = activeIDs.contains { CGDisplayIsBuiltin($0) == 0 }
        let builtInID = onlineDisplayIDs().first { CGDisplayIsBuiltin($0) != 0 }

        guard Settings.autoDisconnectBuiltInOnExternal else {
            // Setting turned off while we had the built-in disabled: restore it.
            if builtInDisabledByUs, let builtInID {
                setBuiltIn(enabled: true, displayID: builtInID)
            }
            return
        }

        guard let builtInID else {
            // No built-in display connected (e.g. headless Mac) — nothing to do.
            return
        }

        if externalActive, !builtInDisabledByUs, CGDisplayIsActive(builtInID) != 0 {
            // External display newly active while the built-in is still on → disable it.
            setBuiltIn(enabled: false, displayID: builtInID)
        } else if !externalActive, builtInDisabledByUs {
            // External display gone; bring the built-in back.
            setBuiltIn(enabled: true, displayID: builtInID)
        }
    }

    /// Enable/disable the built-in, updating the flag *before* the call: `setEnabled` posts
    /// `.fbdDisplaysChanged`, and an observer must not see a stale flag and act on it again.
    /// Rolled back if the call is refused or fails.
    private func setBuiltIn(enabled: Bool, displayID: CGDirectDisplayID) {
        builtInDisabledByUs = !enabled
        if !setEnabled(enabled, displayID: displayID) {
            builtInDisabledByUs = enabled
        }
    }

    // MARK: - Topology queries

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard ids.withUnsafeMutableBufferPointer({
            CGGetActiveDisplayList(UInt32($0.count), $0.baseAddress, &count)
        }) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Online (connected, possibly inactive) display IDs. A soft-disabled
    /// display stays online, so the built-in can be found here for re-enabling.
    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard ids.withUnsafeMutableBufferPointer({
            CGGetOnlineDisplayList(UInt32($0.count), $0.baseAddress, &count)
        }) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
