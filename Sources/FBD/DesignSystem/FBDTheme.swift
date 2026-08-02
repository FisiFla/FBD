import FBDCore
import SwiftUI

/// Design tokens for the FBD interface — the single source for spacing,
/// radii, and motion so the UI stays uniform. All colors are semantic
/// system colors, so dark/light mode adapt automatically.
enum FBDTheme {
    // MARK: Spacing

    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 6
    static let spacingM: CGFloat = 8
    static let spacingL: CGFloat = 12
    static let spacingXL: CGFloat = 16

    // MARK: Radii

    /// Icon tiles inside cards (e.g. the display-kind tile).
    static let radiusTile: CGFloat = 8
    /// Elevated cards (display rows, settings groups).
    static let radiusCard: CGFloat = 12
    /// Inset panels inside a card (DDC controls).
    static let radiusInset: CGFloat = 9

    /// Reserved height for the transparent titlebar strip (traffic lights).
    /// The panel uses .fullSizeContentView, so SwiftUI must reserve this
    /// itself or content slides under the titlebar.
    static let titlebarHeight: CGFloat = 28

    // MARK: Motion

    static let animationFast = Animation.easeOut(duration: 0.12)
    static let animationSpring = Animation.spring(response: 0.28, dampingFraction: 0.7)
}

/// The display-kind visual identity: glyph + tint used by the card header
/// tile and the tags, so built-in / external / virtual displays are
/// distinguishable at a glance.
enum DisplayKind {
    case builtin
    case external
    case virtual

    init(display: Display) {
        if display.isVirtual {
            self = .virtual
        } else if display.isBuiltin {
            self = .builtin
        } else {
            self = .external
        }
    }

    var icon: String {
        switch self {
        case .builtin: return "laptopcomputer"
        case .external: return "display"
        case .virtual: return "rectangle.3.group"
        }
    }

    var label: String {
        switch self {
        case .builtin: return "Built-in"
        case .external: return "External"
        case .virtual: return "Virtual"
        }
    }

    var tint: Color {
        switch self {
        case .builtin: return .blue
        case .external: return .indigo
        case .virtual: return .purple
        }
    }
}
