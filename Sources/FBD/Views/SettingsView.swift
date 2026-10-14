import FBDCore
import SwiftUI

/// Settings, laid out as a sidebar of pages plus a long scrolling pane — the
/// structure a BetterDisplay user expects (`Displays` · `Groups` ·
/// `Application` · `Menu` · `Keyboard` · `About`), rendered in FBD's own idiom.
///
/// The pages themselves live in `SettingsPages.swift`. This file owns the
/// shell, the page vocabulary, and the navigation contract other views use.
@MainActor
struct SettingsView: View {
    /// The Settings pages.
    ///
    /// Not private: a caller that wants to reveal a specific page passes the
    /// page to open on (see `.fbdOpenSettings`).
    enum SettingsPage: String, CaseIterable, Identifiable {
        case displays = "Displays"
        case groups = "Groups"
        case application = "Application"
        case menu = "Menu"
        case keyboard = "Keyboard"
        case about = "About"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .displays: return "display"
            case .groups: return "rectangle.3.group"
            case .application: return "gearshape"
            case .menu: return "menubar.rectangle"
            case .keyboard: return "keyboard"
            case .about: return "info.circle"
            }
        }

        /// Resolves a page from a caller-supplied name, still accepting the tab
        /// names that predate the sidebar so existing callers keep working.
        static func named(_ raw: String?) -> SettingsPage {
            guard let raw else { return .displays }
            if let page = SettingsPage(rawValue: raw) { return page }
            switch raw {
            case "Overview": return .application
            case "Per-Display": return .displays
            default: return .displays
            }
        }
    }

    /// The display a caller asked Settings to reveal, if any. Set from the
    /// `.fbdOpenSettings` userInfo so a per-display action lands on that display
    /// rather than at the top of the list.
    private let targetDisplayID: CGDirectDisplayID?

    @State private var page: SettingsPage

    init(targetDisplayID: CGDirectDisplayID? = nil, initialPage: SettingsPage = .displays) {
        self.targetDisplayID = targetDisplayID
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.35)
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Explicit saturated blue for the switch on-state so active toggles
        // are unmistakable against the material background.
        .tint(.blue)
    }

    /// The page list. Deliberately plain buttons rather than a `List`: the panel
    /// is a floating glass surface and a table-backed sidebar fights it.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases) { item in
                Button {
                    page = item
                } label: {
                    HStack(spacing: FBDTheme.spacingM) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(item.rawValue)
                            .font(.callout)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, FBDTheme.spacingS)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: FBDTheme.radiusTile, style: .continuous)
                            .fill(page == item ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(page == item ? Color.accentColor : Color.primary)
                .accessibilityLabel("\(item.rawValue) settings")
                .accessibilityAddTraits(page == item ? AccessibilityTraits.isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FBDTheme.spacingM)
        // Clear the traffic-light zone, which the panel draws over the content.
        .padding(.top, 36)
        .frame(width: 170, alignment: .topLeading)
    }

    @ViewBuilder
    private var pane: some View {
        switch page {
        case .displays: DisplaySettingsPage(targetDisplayID: targetDisplayID)
        case .groups: GroupsSettingsPage()
        case .application: ApplicationSettingsPage()
        case .menu: MenuSettingsPage()
        case .keyboard: KeyboardSettingsPage()
        case .about: AboutSettingsPage()
        }
    }
}
