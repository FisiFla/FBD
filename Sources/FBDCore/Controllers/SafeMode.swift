import Foundation

/// Startup "safe mode": the escape hatch after a bad display override.
///
/// BetterDisplay lets a user hold **Shift** while launching so stored
/// configuration is *not* re-applied for that session — in particular a custom
/// EDID override and configuration protection. The escape hatch must not depend
/// on the very stored state that broke a display, so the request is carried by
/// the launch gesture (a modifier key). The same request is also carried by the
/// `FBD_SAFE_MODE` environment variable so the behaviour is reachable and
/// testable from the CLI and CI — and by unit tests — where there is no
/// modifier key to hold.
///
/// This type is deliberately **pure**: every decision is a function of the
/// modifier bits and the environment dictionary handed to it, with no AppKit
/// and no global state, so it can be exercised directly.
public enum SafeMode {
    /// Raw value of AppKit's Shift modifier bit (`NSEvent.ModifierFlags.shift`
    /// is `1 << 17`). Spelled out as a plain constant so `isRequested` stays
    /// free of AppKit and is testable on its own.
    public static let shiftModifierMask: UInt = 1 << 17

    /// Environment variable that also requests safe mode; truthy values are
    /// `1`, `true` and `yes` (case-insensitive).
    public static let environmentKey = "FBD_SAFE_MODE"

    /// True when safe mode is requested by either form: the Shift modifier bit
    /// is set in `modifierFlags`, or `environment[environmentKey]` is a truthy
    /// value.
    ///
    /// Pure — the flags and environment are passed in rather than read from
    /// globals.
    public static func isRequested(modifierFlags: UInt, environment: [String: String]) -> Bool {
        if modifierFlags & shiftModifierMask != 0 { return true }
        return isTruthy(environment[environmentKey])
    }

    /// The single predicate the app consults before applying stored state. It
    /// returns `false` whenever safe mode is requested, so a caller that gates
    /// an apply on the result cannot invert it and re-apply the very
    /// configuration the user is escaping.
    ///
    /// Fail-closed by construction: safe mode can only ever *suppress* an
    /// apply, never cause one that would not otherwise have happened.
    ///
    /// - Parameters:
    ///   - modifierFlags: the modifier bits held at launch (0 when unknown).
    ///   - environment: the environment to read `FBD_SAFE_MODE` from.
    public static func shouldApplyStoredState(
        modifierFlags: UInt = 0,
        readFromEnvironment environment: [String: String] = [:]
    ) -> Bool {
        !isRequested(modifierFlags: modifierFlags, environment: environment)
    }

    /// A truthy environment value: `1`, `true` or `yes`, case-insensitive.
    private static func isTruthy(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.lowercased() {
        case "1", "true", "yes": return true
        default: return false
        }
    }
}
