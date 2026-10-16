import FBDCore
import SwiftUI

/// Options that affect the menu-bar panel and the display menus.
@MainActor
struct MenuSettingsPage: View {
    /// Re-renders this page when a setting changes (`Settings` is not observable).
    @ObservedObject private var settingsObserver = SettingsObserver.shared
    var body: some View {
        SettingsPane("Menu") {
            SettingsGroup {
                Toggle("Show offline displays in Settings", isOn: Binding(
                    get: { Settings.showOfflineDisplays },
                    set: { Settings.showOfflineDisplays = $0 }
                ))
                Text("Shows displays the app has seen before even while they are disconnected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Display list", systemImage: "list.bullet")
            }

            SettingsGroup {
                Picker("Icon", selection: Binding(
                    get: { Settings.menuBarIcon },
                    set: { Settings.menuBarIcon = $0 }
                )) {
                    ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                Toggle("Hide the icon when no other display is attached", isOn: Binding(
                    get: { Settings.hideMenuBarIconWhenSingleDisplay },
                    set: { Settings.hideMenuBarIconWhenSingleDisplay = $0 }
                ))
                Text("Hiding takes effect only while Show FBD in the Dock is on (see the OSD section): a menu-bar app with no icon and no Dock icon would have nothing left to click, so the preference is ignored until then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Status item", systemImage: "menubar.rectangle")
            }

            SettingsGroup {
                Text("The panel shows each display's brightness and, where the monitor supports it, volume; quick toggles for Dark Mode, Night Shift, True Tone and Keep Awake; presets; and rows for virtual screens and display groups. Click a display's row for its page, which has every other control for that display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Right-click the status item for Show FBD, Settings…, Check for Updates… and Quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Panel contents", systemImage: "menubar.rectangle")
            }

            SettingsGroup {
                Toggle("Keep the Mac awake", isOn: Binding(
                    get: { Settings.keepAwakeEnabled },
                    set: { _ = KeepAwakeController.shared.setEnabled($0) }
                ))
                Text("Holds a power assertion while FBD runs, so the display stays on through a long transfer, render or presentation. It ends when FBD quits — the assertion belongs to this process, which is why there is no command-line switch for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("System", systemImage: "clock")
            }
        }
    }
}
