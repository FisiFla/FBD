import CoreGraphics
import Foundation
import os

/// The guarded enable/disable action a disconnect policy performs.
///
/// `DisconnectController` implements it with the real CGS path; a test
/// substitutes a recorder, because "a display comes back" only happens on
/// hardware and the policies have to be provable without it.
public protocol DisplayEnabling: AnyObject {
    @discardableResult
    func setEnabled(_ enabled: Bool, displayID: CGDirectDisplayID) -> Bool
}

/// Soft disconnect / reconnect of displays (CGSConfigureDisplayEnabled).
///
/// Disabling a display removes it from the active layout — the screen goes
/// black until it is re-enabled. Automatic use is restricted to the built-in
/// display when `Settings.autoDisconnectBuiltInOnExternal` is on; every other
/// call is user-initiated.
///
/// Three policies live here, and they are kept apart on purpose:
///
/// - **Remembered disconnects** (`DisconnectMemoryStoring`): a display the
///   user asked to keep off is disconnected again every time it comes back —
///   after a replug, after a reboot.
/// - **The docked built-in** (`DockedBuiltInPolicy`): with an external display
///   attached, the built-in panel is turned off so the user works on the
///   external screen.
/// - **The auto-disconnect** (`Settings.autoDisconnectBuiltInOnExternal`): the
///   built-in is turned off when an external display becomes *active*.
///
/// The last two both want the built-in off and are told apart by what they key
/// on — an external *active* versus an external *attached*. They arbitrate
/// through one question ("does anything want the built-in off?"), so neither
/// can switch the panel back on behind the other's back.
///
/// Plain class; the `.fbdDisplaysChanged` callback hops to the main queue.
public final class DisconnectController: DisplayEnabling {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "DisconnectController")

    private var hasRegistered = false
    private var observer: NSObjectProtocol?
    private static let disabledByUsKey = "builtInDisabledByUs"

    private let defaults: UserDefaults

    /// The displays the user asked to keep disconnected. Injected so a test can
    /// prove the behaviour survives a "restart" — a new controller over the
    /// same store — without a real display attached.
    private let memory: DisconnectMemoryStoring

    /// What the machine looks like right now. Injected so the policies can be
    /// exercised with a topology the test machine cannot produce.
    private let topology: DisplayTopology

    /// The action the policies perform. `nil` means "the real one": this
    /// controller's own guarded `setEnabled`.
    private let enabler: DisplayEnabling?

    /// Display ids that were online at the last evaluation. A display that was
    /// already online is not "back" — only one that appears is.
    private var knownOnlineIDs: Set<CGDirectDisplayID> = []

    /// Whether the built-in display may be soft-disconnected on this machine.
    ///
    /// The guard by default; injectable so a test can present a base-M3 Mac,
    /// where the panel may not come back without a reboot.
    var allowsBuiltInDisconnect: () -> Bool = { BuiltInDisconnectGuard.builtInDisconnectAllowed }

    /// Whether the docked policy is on (`Settings.dockedBuiltInOffEnabled`).
    ///
    /// Injectable so a test does not have to write the shared defaults
    /// domain; the setting is read on every evaluation, so a change is picked
    /// up without a restart.
    var dockedBuiltInOffEnabled: () -> Bool = { Settings.dockedBuiltInOffEnabled }

    /// Whether the built-in is turned off when an external display becomes
    /// active (`Settings.autoDisconnectBuiltInOnExternal`). Injectable for
    /// the same reason as `dockedBuiltInOffEnabled`.
    var autoDisconnectBuiltInOnExternal: () -> Bool = { Settings.autoDisconnectBuiltInOnExternal }

    /// True while the built-in display is disabled by us (auto-disconnect active). Persisted:
    /// the disable is committed `.permanently`, so a quit or crash while it is set must still
    /// bring the built-in back on the next launch.
    var builtInDisabledByUs: Bool {
        get { defaults.bool(forKey: Self.disabledByUsKey) }
        set { defaults.set(newValue, forKey: Self.disabledByUsKey) }
    }

    public init(
        defaults: UserDefaults = Settings.defaults,
        memory: DisconnectMemoryStoring? = nil,
        topology: DisplayTopology = CoreGraphicsDisplayTopology(),
        enabler: DisplayEnabling? = nil
    ) {
        self.defaults = defaults
        self.memory = memory ?? UserDefaultsDisconnectMemoryStore(defaults: defaults)
        self.topology = topology
        self.enabler = enabler
    }

    // MARK: - Remembered disconnects

    /// Whether the display is remembered as "keep disconnected".
    public func isDisconnectRemembered(for display: Display) -> Bool {
        memory.isRemembered(display.identityKey)
    }

    /// Remember the display: it is disconnected again every time it comes back.
    ///
    /// A disconnect is a setting, not an event — the desk screen the user
    /// turned off has to stay off after a replug or a reboot.
    public func rememberDisconnect(for display: Display) {
        memory.remember(display.identityKey)
    }

    /// Forget the display: it stays connected from now on.
    public func forgetDisconnect(for display: Display) {
        memory.forget(display.identityKey)
    }

    /// Every display identity the user asked to keep disconnected.
    public func rememberedDisplays() -> [String] {
        memory.rememberedIdentities()
    }

    /// Drop the "keep disconnected" request for the display behind this id.
    ///
    /// Called when a display is re-enabled: the user turning it back on is how
    /// they say "not this time", and a request that outlived that would keep
    /// switching the screen off on the next replug.
    private func forgetRememberedDisconnect(for displayID: CGDirectDisplayID) {
        guard let identity = topology.onlineDisplays()[displayID] else { return }
        guard memory.isRemembered(identity) else { return }
        memory.forget(identity)
    }

    // MARK: - Enable / disable

    /// Disable or re-enable a display in the layout. Black screen on disable —
    /// only auto-used for external displays / user-initiated actions.
    ///
    /// Disconnecting a built-in display is refused on Macs that may not bring it
    /// back without a reboot (base-M3 MacBook Air / entry-level M3 MacBook Pro)
    /// unless the user has set the explicit override — see `BuiltInDisconnectGuard`.
    @discardableResult
    public func setEnabled(_ enabled: Bool, displayID: CGDirectDisplayID) -> Bool {
        if enabled {
            // The user re-enabled it: the "keep it off" request is over.
            forgetRememberedDisconnect(for: displayID)
        }
        if !enabled, CGDisplayIsBuiltin(displayID) != 0, !BuiltInDisconnectGuard.builtInDisconnectAllowed {
            log.error("refusing to disconnect built-in display \(displayID): this Mac's built-in display may not reconnect without a reboot (override in Settings)")
            return false
        }
        do {
            // Hold the DDC bus while the topology changes: WindowServer's
            // display enable waits behind an in-flight I2C transaction and
            // freezes the whole Mac with it.
            try DDCQueuePool.shared.withTrafficPaused {
                try CGSAPI.setEnabled(enabled, displayID: displayID)
            }
        } catch {
            log.warning("setEnabled(\(enabled)) failed for \(displayID): \(error.localizedDescription)")
            return false
        }
        SkyLightAPI.detectDisplays()
        NotificationCenter.default.post(name: .fbdDisplaysChanged, object: nil)
        log.debug("display \(displayID) \(enabled ? "enabled" : "disabled")")
        return true
    }

    /// The action a policy performs: the injected one when there is one, the
    /// real guarded path otherwise.
    private var displayEnabler: DisplayEnabling { enabler ?? self }

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

    // MARK: - Lifecycle

    /// Observe display topology and evaluate the policies.
    public func start() {
        guard !hasRegistered else { return }
        hasRegistered = true
        observer = NotificationCenter.default.addObserver(
            forName: .fbdDisplaysChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evaluate()
        }
        // The first evaluation: the displays that are online right now have
        // just "come back" as far as the remembered disconnects are concerned
        // (this is the reboot case), and the built-in policies have to see the
        // current topology too.
        evaluate()
    }

    /// Run every policy against the current topology.
    func evaluate() {
        evaluateRememberedDisconnects()
        evaluateBuiltInDisplay()
    }

    /// Disconnect the displays the user asked to keep off, when they come back.
    ///
    /// Only displays that *appeared* are considered: a display that was
    /// already online is left alone, so FBD does not fight the user over a
    /// screen they have just re-enabled.
    func evaluateRememberedDisconnects() {
        let online = topology.onlineDisplays()
        let appeared = Set(online.keys).subtracting(knownOnlineIDs)
        knownOnlineIDs = Set(online.keys)
        guard !appeared.isEmpty else { return }
        for id in appeared {
            guard let identity = online[id], memory.isRemembered(identity) else { continue }
            log.info("display \(id) is remembered as disconnected — disconnecting it again")
            _ = displayEnabler.setEnabled(false, displayID: id)
        }
    }

    /// Decide what should happen to the built-in display.
    ///
    /// Two policies want it off — the docked one (an external display is
    /// *attached*) and the auto-disconnect one (an external display is
    /// *active*) — and they are arbitrated by one question, so neither can
    /// switch the panel back on while the other still wants it off.
    ///
    /// The docked policy is decided first and its answer gates the call: on a
    /// base-M3 MacBook the built-in panel may not come back without a reboot,
    /// so the guard has to refuse *before* any SkyLight/CGS call goes out.
    func evaluateBuiltInDisplay() {
        guard let builtInID = topology.builtinDisplayID() else {
            // No built-in display connected (e.g. headless Mac) — nothing to do.
            return
        }
        let online = topology.onlineDisplays()
        let active = topology.activeDisplayIDs()
        let builtInOn = active.contains(builtInID)
        let externalAttached = online.keys.contains(where: isExternal)
        let externalActive = active.contains(where: isExternal)

        let docked = DockedBuiltInPolicy.decide(
            settingEnabled: dockedBuiltInOffEnabled(),
            externalAttached: externalAttached,
            builtInEnabled: builtInOn,
            guardAllowsDisconnect: allowsBuiltInDisconnect()
        )
        switch docked {
        case .turnOff:
            log.info("docked: an external display is attached — turning the built-in display off")
        case .keepOn(let reason):
            switch reason {
            case .guardRefused:
                log.notice("docked: the built-in display stays on — this Mac's built-in display may not reconnect without a reboot")
            default:
                log.debug("docked: the built-in display stays on (\(reason.rawValue))")
            }
        }

        let wantsOff = docked == .turnOff
            || (autoDisconnectBuiltInOnExternal() && externalActive)

        if wantsOff {
            if builtInOn, !builtInDisabledByUs {
                setBuiltIn(enabled: false, displayID: builtInID)
            }
        } else if builtInDisabledByUs {
            // Nothing wants the built-in off any more — bring it back.
            setBuiltIn(enabled: true, displayID: builtInID)
        }
    }

    /// Whether the display is an external one: not the built-in panel, and not
    /// one of FBD's own virtual screens (the user plugged nothing in).
    private func isExternal(_ displayID: CGDirectDisplayID) -> Bool {
        !topology.isBuiltin(displayID) && !VirtualDisplayRegistry.shared.contains(displayID)
    }

    /// Enable/disable the built-in, updating the flag *before* the call: `setEnabled` posts
    /// `.fbdDisplaysChanged`, and an observer must not see a stale flag and act on it again.
    /// Rolled back if the call is refused or fails.
    private func setBuiltIn(enabled: Bool, displayID: CGDirectDisplayID) {
        builtInDisabledByUs = !enabled
        if !displayEnabler.setEnabled(enabled, displayID: displayID) {
            builtInDisabledByUs = enabled
        }
    }
}
