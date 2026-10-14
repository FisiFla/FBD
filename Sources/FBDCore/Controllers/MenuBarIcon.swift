import Foundation

/// The status item's icon, and whether the item is shown at all.
///
/// Both rules are pure so they can be tested without a status item. The icon
/// set is deliberately closed rather than free text: this item is a menu-bar
/// app's only permanent surface, so a symbol name that fails to resolve — a
/// typo, or a symbol added in a newer macOS than the one running — would leave
/// the button blank and the app unreachable. Only names measured to resolve on
/// macOS 27 are offered, and applying one still falls back if that ever changes.
public enum MenuBarIconStyle: String, Codable, CaseIterable, Sendable {
    case display
    case displayPair = "display.2"
    case sun = "sun.max"
    case moon
    case moonStars = "moon.stars"
    case mirrors = "rectangle.on.rectangle"
    case laptop = "laptopcomputer"
    case screen = "tv"
    case sparkle = "sparkles"
    case contrast = "circle.lefthalf.filled"
    case sliders = "slider.horizontal.3"
    case inset = "rectangle.inset.filled"

    /// The icon FBD has always used, and the one an unrecognised stored value
    /// degrades to.
    public static let `default`: MenuBarIconStyle = .display

    /// The SF Symbol name for `NSImage(systemSymbolName:)`.
    public var symbolName: String { rawValue }

    public var label: String {
        switch self {
        case .display: return "Display"
        case .displayPair: return "Two displays"
        case .sun: return "Sun"
        case .moon: return "Moon"
        case .moonStars: return "Moon and stars"
        case .mirrors: return "Mirrored displays"
        case .laptop: return "Laptop"
        case .screen: return "Screen"
        case .sparkle: return "Sparkle"
        case .contrast: return "Contrast"
        case .sliders: return "Sliders"
        case .inset: return "Inset display"
        }
    }
}

/// Whether the status item should be present at all.
public enum MenuBarIconPolicy {
    /// - Parameters:
    ///   - hideWhenSingleDisplay: the stored preference.
    ///   - hasExternalDisplay: whether a display other than the built-in one is
    ///     attached. A desktop Mac with no built-in panel always has one, so the
    ///     item is never hidden there.
    ///   - showDockIcon: whether the app is reachable from the Dock.
    ///
    /// Hiding is refused unless a Dock icon is enabled. FBD is a menu-bar
    /// accessory: with the item hidden and no Dock icon there is no surface left
    /// to click, so the preference would strand the user with no way back short
    /// of relaunching. Failing closed here means a stored preference can never
    /// make the app unreachable — only once a Dock icon exists to fall back to
    /// does it take effect.
    public static func isStatusItemVisible(
        hideWhenSingleDisplay: Bool,
        hasExternalDisplay: Bool,
        showDockIcon: Bool
    ) -> Bool {
        guard hideWhenSingleDisplay, !hasExternalDisplay else { return true }
        return !showDockIcon
    }
}
