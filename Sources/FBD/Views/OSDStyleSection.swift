import FBDCore
import SwiftUI

/// The HUD's on/off switch, look and placement.
///
/// Its own view because the whole style is **one stored value**: the controls bind
/// to a local copy and save it on change, rather than each writing its own key —
/// which would split one setting across several and allow a partial write.
@MainActor
struct OSDStyleSection: View {
    @State private var style = OSDStyle.load()

    var body: some View {
        Group {
            Toggle("Custom OSD", isOn: bool(Settings.customOSDEnabled) { Settings.customOSDEnabled = $0 })
            Text("Shows a brightness HUD when FBD changes the display brightness.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
