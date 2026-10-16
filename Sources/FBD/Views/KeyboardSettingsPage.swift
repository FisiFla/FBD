import FBDCore
import SwiftUI

/// Media-key handling and which display the keys act on.
@MainActor
struct KeyboardSettingsPage: View {
    /// Re-renders this page when a setting changes; also carries the latched hotkeys-unavailable flag.
    @ObservedObject private var settingsObserver = SettingsObserver.shared

    var body: some View {
        Form {
            Section {
                Toggle("Intercept media keys", isOn: Binding(
                    get: { Settings.interceptMediaKeys },
                    set: { Settings.interceptMediaKeys = $0 }
                ))
                Text("Off by default: FBD only takes the F1/F2 and F10–F12 keys when you opt in. Requires Accessibility permission, and only affects keys while FBD is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settingsObserver.hotkeysUnavailable {
                    Label("Media keys unavailable — allow Accessibility for FBD in System Settings", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("Media keys", systemImage: "keyboard")
            }

            Section {
                Picker("Brightness and volume keys affect", selection: targetBinding) {
                    ForEach(KeyboardControlTarget.allCases, id: \.self) { target in
                        Text(label(for: target)).tag(target)
                    }
                }
                Text(caption(for: Settings.keyboardControlTarget))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Keyboard control target", systemImage: "cursorarrow.rays")
            }
        }
        .formStyle(.grouped)
    }

    private var targetBinding: Binding<KeyboardControlTarget> {
        Binding(
            get: { Settings.keyboardControlTarget },
            set: { Settings.keyboardControlTarget = $0 }
        )
    }

    private func label(for target: KeyboardControlTarget) -> String {
        switch target {
        case .mouseScreen: return "Screen with the mouse pointer"
        case .focusedScreen: return "Screen with the window in focus"
        case .allSuitableScreens: return "All suitable screens"
        case .audioDeviceMatch: return "Display matching the current audio device"
        }
    }

    private func caption(for target: KeyboardControlTarget) -> String {
        switch target {
        case .mouseScreen: return "Keys adjust the display under the pointer."
        case .focusedScreen: return "Keys adjust the display showing the focused window."
        case .allSuitableScreens: return "Keys adjust every connected display that has brightness or volume control."
        case .audioDeviceMatch: return "Keys adjust the display whose name matches the current audio device, falling back to the display under the pointer."
        }
    }
}
