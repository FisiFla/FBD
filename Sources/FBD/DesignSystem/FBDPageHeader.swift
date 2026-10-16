import SwiftUI

/// Slim header for pages below home: floating glass capsule with ‹ and the title.
/// Shares `namespace` with the root so the capsule morphs between pages.
struct FBDPageHeader: View {
    let title: String
    let namespace: Namespace.ID
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: FBDTheme.spacingS) {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            // A glass button, not a plain one: inside the glass capsule a plain button
            // intermittently dropped the first click after the header appeared (macOS 27).
            .fbdGlassButton()
            .controlSize(.small)
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityLabel(Text("Back"))
            .accessibilityIdentifier("panel.back")
            Text(title).font(FBDTheme.Font.displayName).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FBDTheme.spacingM)
        .padding(.vertical, FBDTheme.spacingXS)
        .fbdGlass(in: Capsule())
        .fbdGlassID("page-header", in: namespace)
    }
}
