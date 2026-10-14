import Foundation

/// How the brightness/volume HUD looks and where it sits.
///
/// Every field is clamped rather than trusted: this is persisted JSON, and a value
/// written by a newer version (or hand-edited) must not be able to produce a HUD
/// nobody can read or a radius that clips the content away.
public struct OSDStyle: Codable, Equatable, Sendable {
    /// Where the HUD sits on its screen.
    public enum Position: String, Codable, CaseIterable, Sendable {
        case topCenter, topLeading, topTrailing, bottomCenter

        public var label: String {
            switch self {
            case .topCenter: return "Top centre"
            case .topLeading: return "Top left"
            case .topTrailing: return "Top right"
            case .bottomCenter: return "Bottom centre"
            }
        }
    }

    /// How the value is drawn.
    public enum BarStyle: String, Codable, CaseIterable, Sendable {
        /// A continuous bar — the default, and what FBD has always shown.
        case continuous
        /// Discrete segments, so the level is readable at a glance.
        case segmented

        public var label: String {
            switch self {
            case .continuous: return "Continuous"
            case .segmented: return "Segmented"
            }
        }
    }

    /// The HUD background's relationship to the system appearance.
    public enum Background: String, Codable, CaseIterable, Sendable {
        /// The dark HUD material, whatever the system appearance. The incumbent
        /// look, and the default.
        case hudDark
        /// Follows the system's light/dark appearance.
        case adaptive
        /// The OS's glass material — the one the system HUD uses on macOS 26 and later, so the HUD
        /// samples what is behind it rather than drawing a flat panel. Below macOS 26 there is no
        /// such view and it falls back to the dark HUD material.
        case glass

        public var label: String {
            switch self {
            case .hudDark: return "Dark HUD"
            case .adaptive: return "Follow system"
            case .glass: return "Glass"
            }
        }
    }

    public var position: Position
    public var barStyle: BarStyle
    public var background: Background
    public var showsShadow: Bool
    public var cornerRadius: Double
    /// Segments drawn for `.segmented`. Ignored for `.continuous`.
    public var segmentCount: Int

    public static let defaultCornerRadius: Double = 12
    public static let defaultSegmentCount = 16
    /// Bounds. The radius may not exceed half the HUD's short side or it would
    /// clip the content; 28 keeps it well inside that at any content size.
    public static let cornerRadiusRange: ClosedRange<Double> = 0...28
    public static let segmentCountRange: ClosedRange<Int> = 4...32

    public init(
        position: Position = .topCenter,
        barStyle: BarStyle = .continuous,
        background: Background = .hudDark,
        showsShadow: Bool = true,
        cornerRadius: Double = OSDStyle.defaultCornerRadius,
        segmentCount: Int = OSDStyle.defaultSegmentCount
    ) {
        self.position = position
        self.barStyle = barStyle
        self.background = background
        self.showsShadow = showsShadow
        self.cornerRadius = cornerRadius
        self.segmentCount = segmentCount
    }

    /// The defaults, which are exactly the look FBD shipped before this was
    /// configurable — so an existing install is unaffected until something is
    /// changed, and a corrupt stored blob lands here rather than on a surprise.
    public static let standard = OSDStyle()

    /// Bring every field inside its range. Non-finite values fall back to the
    /// default rather than clamping to an extreme; see `BrightnessPreferences`
    /// for the same rule and the reasoning.
    public func clamped() -> OSDStyle {
        var result = self
        result.cornerRadius = Self.clampNits(cornerRadius, fallback: Self.defaultCornerRadius, to: Self.cornerRadiusRange)
        result.segmentCount = min(max(segmentCount, Self.segmentCountRange.lowerBound), Self.segmentCountRange.upperBound)
        return result
    }

    private static func clampNits(
        _ value: Double,
        fallback: Double,
        to range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Persistence

    /// Read the stored style, clamped. Anything unreadable yields `.standard`.
    public static func load(defaults: UserDefaults = Settings.defaults) -> OSDStyle {
        guard let data = defaults.data(forKey: Settings.osdStyleKey),
              let style = try? JSONDecoder().decode(OSDStyle.self, from: data) else {
            return .standard
        }
        return style.clamped()
    }

    public static func save(_ style: OSDStyle, defaults: UserDefaults = Settings.defaults) {
        guard let data = try? JSONEncoder().encode(style.clamped()) else { return }
        defaults.set(data, forKey: Settings.osdStyleKey)
    }
}
