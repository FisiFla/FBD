import SwiftUI

/// Small secondary section title used between the home page's blocks.
struct SectionHeader: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(FBDTheme.Font.sectionHeader)
            .foregroundStyle(.secondary)
            .padding(.horizontal, FBDTheme.spacingM)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A section header over its content — the display page and the per-display sections
/// it embeds group their rows this way.
struct TitledSection<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FBDTheme.spacingXS) {
            SectionHeader(title)
            content
        }
    }
}
