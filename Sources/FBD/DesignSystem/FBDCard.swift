import SwiftUI

/// The standard display-card surface: a rounded panel with a hairline border.
///
/// This was copied verbatim into four views. The copies were still identical on
/// the day it was extracted, which is the point — they had not drifted *yet*, and
/// four hand-maintained copies of a fill and a border is exactly how the card
/// padding and radii started to disagree elsewhere in the app.
///
/// Padding is deliberately left to the caller: the sites genuinely differ there.
/// A display row pads *inside* the surface, while the virtual-screen and group
/// lists pad *outside* it.
struct FBDCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: FBDTheme.radiusCard, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: FBDTheme.radiusCard, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

extension View {
    /// Apply the standard display-card surface.
    func fbdCard() -> some View {
        modifier(FBDCard())
    }
}
