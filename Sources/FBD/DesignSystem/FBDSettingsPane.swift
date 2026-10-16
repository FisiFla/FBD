import SwiftUI

/// The Settings window's page container and its grouped cards, in the popover's design language
/// (glass surfaces, round icon chips, flat rows) instead of the stock grouped `Form`.
///
/// `SettingsGroup` takes the same `content` / `header` / `footer` closures as `Section`, so a
/// page converts by renaming `Form` → `SettingsPane` and `Section` → `SettingsGroup`.

/// A scrolling page: a large title over a column of cards.
struct SettingsPane<Content: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBDTheme.spacingXL) {
                if let title {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 2)
                }
                content()
            }
            .padding(.horizontal, FBDTheme.settingsPanePadding)
            .padding(.vertical, FBDTheme.settingsPanePadding)
            .frame(maxWidth: FBDTheme.settingsPaneMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One glass card of related settings: an optional header (a `Label` renders with the round chip),
/// the rows, and an optional footer caption.
struct SettingsGroup<Content: View, Header: View, Footer: View>: View {
    let content: Content
    let header: Header
    let footer: Footer

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FBDTheme.spacingS) {
            if Header.self != EmptyView.self {
                header
                    .labelStyle(FBDGroupLabelStyle())
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 2)
            }
            VStack(alignment: .leading, spacing: FBDTheme.spacingL) {
                content
            }
            .toggleStyle(.fbdTrailingSwitch)
            .padding(FBDTheme.spacingXL)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fbdGlass(in: RoundedRectangle(cornerRadius: FBDTheme.radiusCard + 4, style: .continuous))
            if Footer.self != EmptyView.self {
                footer
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, FBDTheme.spacingL)
            }
        }
    }
}

extension SettingsGroup where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension SettingsGroup where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension SettingsGroup where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

extension SettingsGroup where Header == Text, Footer == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

/// The header icon sits in the same round chip the popover's rows use.
struct FBDGroupLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: FBDTheme.spacingM) {
            configuration.icon
                .font(.system(size: 12, weight: .medium))
                .frame(width: FBDTheme.chipSize, height: FBDTheme.chipSize)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            configuration.title
        }
    }
}

/// A sidebar item: a tinted rounded-square chip, as in System Settings.
struct FBDSidebarLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: FBDTheme.spacingL) {
            configuration.icon
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient))
            configuration.title
        }
    }
}
