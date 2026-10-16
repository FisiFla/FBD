import FBDCore
import SwiftUI

/// The popover: one glass backdrop, a page stack that slides horizontally, and a header
/// capsule that morphs between pages.
struct PanelRootView: View {
    @ObservedObject var model: PanelModel
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var notice = FBDNotice.shared
    @State private var rosettaWarningVisible = PanelRootView.rosettaWarningActive

    var body: some View {
        FBDGlassContainer(spacing: FBDTheme.spacingM) {
            VStack(alignment: .leading, spacing: FBDTheme.spacingM) {
                if model.route != .home {
                    FBDPageHeader(title: title(for: model.route), namespace: glassNamespace) { model.back() }
                }
                // On every page, and outside the page transition so they don't slide with it.
                // Menus dismiss on selection, so failures reported from them land here.
                FBDNoticeBanner(notice: notice)
                if rosettaWarningVisible {
                    RosettaWarningView()
                }
                ScrollView(.vertical, showsIndicators: false) {
                    page(for: model.route)
                        .id(model.route)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
            }
            .padding(FBDTheme.spacingL)
        }
        .frame(width: FBDTheme.panelWidth)
        .animation(reduceMotion ? nil : FBDTheme.animationPanel, value: model.route)
        .environment(\.panelGlassNamespace, glassNamespace)
        // The panel is non-activating and often not key; without this, switches and sliders
        // render in the gray inactive variant whenever another window has focus.
        .environment(\.controlActiveState, .key)
        .onReceive(NotificationCenter.default.publisher(for: .fbdRosettaWarningActive)) { _ in
            rosettaWarningVisible = true
        }
    }

    /// Whether the Rosetta warning banner applies to this process.
    static var rosettaWarningActive: Bool {
        IOAVServiceAPI.isAppleSilicon && IOAVServiceAPI.isRunningUnderRosetta && Settings.showRosettaWarning
    }

    @ViewBuilder
    private func page(for route: PanelRoute) -> some View {
        switch route {
        case .home: HomePage(model: model)
        case .display(let id): if let d = model.display(id: id) { DisplayDetailPage(model: model, display: d) }
        case .allModes(let id): if let d = model.display(id: id) { AllModesPage(model: model, display: d) }
        case .virtualScreens: VirtualScreensPage(model: model)
        case .groups: GroupsPage(model: model)
        case .newPreset(let id): if let d = model.display(id: id) { NewPresetPage(model: model, display: d) }
        }
    }

    private func title(for route: PanelRoute) -> String {
        switch route {
        case .home: return ""
        case .display(let id), .newPreset(let id): return model.display(id: id)?.name ?? ""
        case .allModes: return String(localized: "All Modes")
        case .virtualScreens: return String(localized: "Virtual Screens")
        case .groups: return String(localized: "Display Groups")
        }
    }
}

private struct PanelGlassNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    var panelGlassNamespace: Namespace.ID? {
        get { self[PanelGlassNamespaceKey.self] }
        set { self[PanelGlassNamespaceKey.self] = newValue }
    }
}
