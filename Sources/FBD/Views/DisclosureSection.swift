import SwiftUI

/// Consistent disclosure-row style: small icon + title + chevron.
/// Shared by the display row and its per-capability section children so
/// every disclosure (Filters, Resolutions, XDR/HDR, EDID) renders alike.
func disclosureSection<Content: View>(
    icon: String,
    title: String,
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
