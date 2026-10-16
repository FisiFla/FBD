import FBDCore
import SwiftUI

/// Settings, laid out as a native sidebar of pages (`Displays` · `Groups` · `Application` ·
/// `Menu` · `Keyboard` · `About`) beside a grouped form, in the standard Settings window.
///
/// The pages themselves live in `Settings*Page.swift` files. This file owns the
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

        var tint: Color {
            switch self {
            case .displays: return .blue
            case .groups: return .purple
            case .application: return .gray
            case .menu: return .orange
            case .keyboard: return .teal
            case .about: return .indigo
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
    /// Settings actions report refusals through `FBDNotice` too; the popover's banner is not on
    /// screen while this window is, so the window hosts its own.
    @ObservedObject private var notice = FBDNotice.shared

    init(targetDisplayID: CGDirectDisplayID? = nil, initialPage: SettingsPage = .displays) {
        self.targetDisplayID = targetDisplayID
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { item in
                Label(item.title, systemImage: item.symbol)
                    .labelStyle(FBDSidebarLabelStyle(tint: item.tint))
                    .tag(item)
                    .accessibilityLabel(item.settingsLabel)
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            pane
                .safeAreaInset(edge: .top, spacing: 0) {
                    if notice.message != nil {
                        FBDNoticeBanner(notice: notice)
                            .padding(.vertical, FBDTheme.spacingS)
                            .background(.bar)
                    }
                }
        }
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
