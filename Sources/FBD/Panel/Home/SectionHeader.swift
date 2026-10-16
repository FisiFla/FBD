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
