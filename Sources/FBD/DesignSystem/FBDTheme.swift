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
    /// Inset wells inside a panel band (DDC controls).
    static let radiusInset: CGFloat = 9

    /// Reserved height for the transparent titlebar strip (traffic lights).
    /// The panel uses .fullSizeContentView, so SwiftUI must reserve this
    /// itself or content slides under the titlebar.
    static let titlebarHeight: CGFloat = 28

    // MARK: Motion

    static let animationFast = Animation.easeOut(duration: 0.12)

    /// Panel-level state changes: opening Settings, expanding a footer section.
    ///
    /// Replaces `spring(response: 0.28, dampingFraction: 0.7)` — 280 ms *with*
    /// bounce. This is a tool the user is mid-task with, so a transition should
    /// confirm the state change and get out of the way: inside the 150–250 ms
    /// band, eased out, no bounce or elastic.
    static let animationPanel = Animation.easeOut(duration: 0.22)

    // MARK: Surfaces

    /// Strength of the panel's chrome band — the header, settings header and tools
    /// footer.
    ///
    /// A `labelColor` shade, not a second material. The panel's backdrop is already
    /// a glass layer (`FrostedBackground`), and material guidance keeps glass on the
    /// functional layer only: stacking a material inside the glass is
    /// glass-on-glass, which flattens the hierarchy and makes the chrome compete
    /// with the content it frames. See `fbdChromeBand()`.
    static let chromeBandOpacity: Double = 0.08

    /// The panel's content bands.
    ///
    /// The panel is *one* surface — its own backdrop — and the chrome already reads that way
    /// (`fbdChromeBand`). Rows used to be rounded cards floating on top of it, each with its own
    /// fill and border, which is the glass-on-glass stacking the chrome fix was about, one level
    /// down. A row is now a full-width band of this shade instead: same surface, no second
    /// layer, and the divider between rows does the separating rather than a gap.
    static let panelBandOpacity: Double = 0.035
}

extension View {
    /// Give an icon-only control a hit target of at least 28×28 pt — the macOS
    /// convention — without enlarging the glyph.
    ///
    /// A bare `Image(systemName:)` inside a borderless button is only as large as
    /// its glyph (roughly 12–16 pt for the symbols used here), which is a hard
    /// target to hit deliberately and easy to miss mid-movement.
    func fbdIconButton() -> some View {
        frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
    }

    /// The panel's chrome band: the header, the settings header, the tools footer.
    ///
    /// A flat shade rather than `.ultraThinMaterial`. The panel sits on a glass
    /// backdrop, so a material here was glass stacked on glass — the content-layer
    /// rule this came from is that glass belongs to the chrome and content uses a
    /// standard surface. It also stops three live blurs re-sampling the same
    /// backdrop every time the panel redraws.
    func fbdChromeBand() -> some View {
        background(Color.primary.opacity(FBDTheme.chromeBandOpacity))
    }

    /// The panel's row surface: a full-width band rather than a floating rounded card, so the
    /// panel stays one surface. See `FBDTheme.panelBandOpacity`.
    func fbdPanelBand() -> some View {
        background(Color.primary.opacity(FBDTheme.panelBandOpacity))
    }
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
