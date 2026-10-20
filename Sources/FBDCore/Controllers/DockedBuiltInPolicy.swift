import Foundation

/// Whether the built-in display should be turned off while an external display
/// is attached.
///
/// The user who docks a laptop wants the desk screen, not the laptop panel —
/// so the built-in display is switched off while an external display is
/// attached and the user is working on the external one.
///
/// Two things make this more than a switch:
///
/// - **It is off by default.** Turning a panel off without being asked is
///   never silent; the user opts in.
/// - **On a base-M3 MacBook the built-in panel may not come back** without a
///   reboot, so the decision has to be taken *before* any SkyLight/CGS call
///   is made — not after a call that already went out. That is why the
///   decision lives in this pure function: the caller can act on the answer
///   without ever touching the display API on the refusing path.
///
/// The lid needs no separate probe: a closed lid already switches the built-in
/// panel off, so "the built-in display is on" *is* the lid-open signal.
public enum DockedBuiltInPolicy {
    /// Why the built-in display is being left on.
    public enum Reason: String, Equatable, Sendable {
        /// The setting is off — the default.
        case settingDisabled
        /// No external display is attached.
        case noExternalAttached
        /// The built-in display is already off (a closed lid, or a disconnect).
        case builtInAlreadyOff
        /// The built-in-disconnect guard refuses on this Mac.
        case guardRefused
    }

    /// What to do with the built-in display.
    public enum Decision: Equatable, Sendable {
        /// Turn the built-in display off.
        case turnOff
        /// Leave the built-in display on, and say why.
        case keepOn(reason: Reason)
    }

    /// The decision, as a function of the four facts that decide it.
    ///
    /// - Parameters:
    ///   - settingEnabled: `Settings.dockedBuiltInOffEnabled` — the user's opt-in.
    ///   - externalAttached: an external display is *attached* (online). The
    ///     docked policy keys on attachment, not on activity: the existing
    ///     `autoDisconnectBuiltInOnExternal` policy keys on an external display
    ///     becoming *active*, and the two are kept apart.
    ///   - builtInEnabled: the built-in display is currently on.
    ///   - guardAllowsDisconnect: `BuiltInDisconnectGuard.builtInDisconnectAllowed`.
    /// - Returns: `.turnOff`, or `.keepOn(reason:)` with the reason nothing
    ///   happened.
    public static func decide(
        settingEnabled: Bool,
        externalAttached: Bool,
        builtInEnabled: Bool,
        guardAllowsDisconnect: Bool
    ) -> Decision {
        guard settingEnabled else { return .keepOn(reason: .settingDisabled) }
        guard externalAttached else { return .keepOn(reason: .noExternalAttached) }
        guard builtInEnabled else { return .keepOn(reason: .builtInAlreadyOff) }
        // The guard is checked last, but still before anything is called: the
        // answer decides whether a call is made at all.
        guard guardAllowsDisconnect else { return .keepOn(reason: .guardRefused) }
        return .turnOff
    }
}
