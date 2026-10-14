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

        /// The sidebar name.
        ///
        /// A `switch` over the cases, not `rawValue`: `Text(String)` renders verbatim, so
        /// `Text(item.rawValue)` was never looked up and no translation could reach it. Spelling
        /// the cases out keeps each key a *literal*, which is also what lets the drift test verify
        /// it exists in the source — a key built at runtime from `rawValue` would have to match it
        /// byte-for-byte with nothing checking that it did.
        var title: LocalizedStringKey {
            switch self {
            case .displays: return "Displays"
            case .groups: return "Groups"
            case .application: return "Application"
            case .menu: return "Menu"
            case .keyboard: return "Keyboard"
            case .about: return "About"
            }
        }

        /// VoiceOver's name for the sidebar item, which says what the item is rather than only
        /// what it is called: "Displays settings" reads better than "Displays" out of context.
        var settingsLabel: LocalizedStringKey {
            switch self {
            case .displays: return "Displays settings"
            case .groups: return "Groups settings"
            case .application: return "Application settings"
            case .menu: return "Menu settings"
            case .keyboard: return "Keyboard settings"
            case .about: return "About settings"
            }
        }

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
                        Text(item.title)
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
                .accessibilityLabel(item.settingsLabel)
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
