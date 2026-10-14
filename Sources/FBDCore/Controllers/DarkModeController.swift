import CPrivateAPI
import Foundation
import os

/// What an appearance argument asks for.
///
/// A value type so the vocabulary the CLI accepts is testable without a display, a window server
/// or a Mac that can actually switch appearance. `report` is the empty case, because reading is
/// the useful default: running the command with no argument should say where things stand.
public enum DarkModeRequest: Equatable, Sendable {
    case on
    case off
    case report

    /// Parses one argument. Returns nil for anything unrecognised, so a typo is refused rather
    /// than silently treated as a read.
    public static func parse(_ raw: String?) -> DarkModeRequest? {
        guard let raw else { return .report }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "": return .report
        case "status", "report", "get": return .report
        case "on", "dark", "true", "yes", "1": return .on
        case "off", "light", "false", "no", "0": return .off
        default: return nil
        }
    }
}

/// System Dark Mode: read it, switch it, and know when something else switched it.
///
/// The mechanism is SkyLight's appearance theme — the switch Control Center flips — reached
/// through the C shims in `Sources/CPrivateAPI`, so nothing private is declared in Swift and a
/// Mac without those symbols degrades to "unavailable" instead of crashing. Crisp resolves the
/// same three functions, which is where the names came from; it also prefers the notifying
/// variant so the switch animates like Control Center's, and that is the default here.
///
/// This is a *system* switch, not a per-display one: it is not stored in `Settings`, because the
/// system owns it and anything else that changes it must be reflected rather than remembered.
public final class DarkModeController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "DarkModeController")

    /// Posted by the system when the appearance changes, whoever changed it.
    public static let themeChangedNotification = Notification.Name("AppleInterfaceThemeChangedNotification")

    public init() {}

    /// True when the appearance can be read *and* written on this Mac.
    public var isAvailable: Bool { FBDAppearanceAvailable() }

    /// Whether the system is in Dark Mode, or nil when it cannot be read.
    public func isDark() -> Bool? {
        var dark = false
        guard FBDAppearanceIsDark(&dark) else {
            log.warning("SLSGetAppearanceThemeLegacy unavailable — Dark Mode control disabled")
            return nil
        }
        return dark
    }

    /// Switch the system appearance. `animated` uses the crossfade Control Center uses when that
    /// entry point exists, and falls back to the instant flip when it does not.
    ///
    /// Returns false when the switch could not be made at all, so a caller never reports success
    /// for a no-op.
    @discardableResult
    public func setDark(_ on: Bool, animated: Bool = true) -> Bool {
        guard FBDAppearanceSetDark(on, animated) else {
            log.warning("appearance set failed — Dark Mode control unavailable")
            return false
        }
        return true
    }
}
