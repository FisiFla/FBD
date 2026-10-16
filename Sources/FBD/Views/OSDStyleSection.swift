import FBDCore
import SwiftUI

@MainActor
/// The HUD's look and placement, plus the Dock visibility rules.
///
/// Its own view because the whole style is **one stored value**: the controls bind
/// to a local copy and save it on change, rather than each writing its own key —
/// which would split one setting across several and allow a partial write.
struct OSDStyleSection: View {
    @State private var style = OSDStyle.load()

    var body: some View {
        Group {
            SettingsRow(title: "HUD position") {
                Picker("", selection: $style.position) {
                    ForEach(OSDStyle.Position.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            SettingsRow(title: "HUD bar") {
                Picker("", selection: $style.barStyle) {
                    ForEach(OSDStyle.BarStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            SettingsRow(title: "HUD background") {
                Picker("", selection: $style.background) {
                    ForEach(OSDStyle.Background.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            Toggle("HUD shadow", isOn: $style.showsShadow)

            SettingsSliderRow(
                title: "HUD corner radius",
                value: style.cornerRadius,
                range: OSDStyle.cornerRadiusRange,
                format: { "\(Int($0))" },
                caption: nil,
                onChange: { style.cornerRadius = $0 }
            )

            Toggle("Show FBD in the Dock", isOn: bool(Settings.showDockIcon) { Settings.showDockIcon = $0 })
            Toggle("Brief Dock icon at launch", isOn: bool(Settings.briefDockIconAtStartup) { Settings.briefDockIconAtStartup = $0 })
            Text("A menu-bar app normally has no Dock icon. These make it findable there — permanently, or only just after it opens.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: style) { newValue in OSDStyle.save(newValue) }
    }

    /// The same shape as the page's own helper: the `@autoclosure @escaping
    /// @Sendable` signatures are what keep the closure out of the main actor, and
    /// without them SwiftUI's `Binding` init warns about a non-Sendable capture.
    private func bool(
        _ get: @autoclosure @escaping @Sendable () -> Bool,
        set: @escaping @Sendable (Bool) -> Void
    ) -> Binding<Bool> {
        Binding(get: get, set: set)
    }
}
