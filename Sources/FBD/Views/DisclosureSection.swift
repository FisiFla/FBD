import SwiftUI

/// Consistent disclosure-row style: small icon + title + chevron.
/// Shared by the display row and its per-capability section children so
/// every disclosure (Filters, Resolutions, XDR/HDR, EDID) renders alike.
func disclosureSection<Content: View>(
    icon: String,
    /// `LocalizedStringKey`, not `String`: `Label(String, systemImage:)` renders verbatim, so the
    /// section titles were unreachable by translation until this changed.
    title: LocalizedStringKey,
    @ViewBuilder content: @escaping () -> Content
) -> some View {
    DisclosureGroup {
        content()
            .padding(.top, 4)
    } label: {
        Label(title, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
