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
    /// True while the built-in display is disabled by us (auto-disconnect active).
    private var builtInDisabledByUs = false

    public init() {}

    /// Disable or re-enable a display in the layout. Black screen on disable —
    /// only auto-used for external displays / user-initiated actions.
    @discardableResult
    public func setEnabled(_ enabled: Bool, displayID: CGDirectDisplayID) -> Bool {
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
                builtInDisabledByUs = !setEnabled(true, displayID: builtInID)
            }
            return
        }

        guard let builtInID else {
            // No built-in display connected (e.g. headless Mac) — nothing to do.
            return
        }

        if externalActive, !builtInDisabledByUs, CGDisplayIsActive(builtInID) != 0 {
            // External display newly active while the built-in is still on → disable it.
            builtInDisabledByUs = setEnabled(false, displayID: builtInID)
        } else if !externalActive, builtInDisabledByUs {
            // External display gone; bring the built-in back.
            builtInDisabledByUs = !setEnabled(true, displayID: builtInID)
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
