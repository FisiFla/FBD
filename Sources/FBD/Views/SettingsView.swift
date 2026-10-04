import FBDCore
import os
import ServiceManagement
import SwiftUI

/// Settings panel: launch at login, DDC cooldown, Rosetta warning toggle,
/// experimental unsafe modes, virtual displays & layout protection, and an
/// About section.
@MainActor
struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hotkeysUnavailable = false
    @State private var layoutProtection = LayoutProtectionController()
    @State private var hasSavedArrangement = false
    @State private var nightShift = NightShiftController()
    @State private var trueTone = TrueToneController()
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "App")

    /// Settings tabs: the overview form, or per-display settings.
    ///
    /// Not private: a caller that wants to reveal a specific display passes the
    /// tab to open on.
    enum SettingsTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case perDisplay = "Per-Display"
        var id: String { rawValue }
    }

    /// The display a caller asked Settings to reveal, if any. Set from the
    /// `.fbdOpenSettings` userInfo so a per-display action lands on that display
    /// rather than at the top of the list.
    private let targetDisplayID: CGDirectDisplayID?

    @State private var settingsTab: SettingsTab

    init(targetDisplayID: CGDirectDisplayID? = nil, initialTab: SettingsTab = .overview) {
        self.targetDisplayID = targetDisplayID
        _settingsTab = State(initialValue: initialTab)
    }

    private var configProtectionBinding: Binding<Bool> {
        Binding(
            get: { Settings.configProtectionEnabled },
            set: { enabled in
                Settings.configProtectionEnabled = enabled
                if enabled { saveConfigurationSnapshot() }
            }
        )
    }

    /// Snapshot every online display's current state when protection is enabled.
    ///
    /// This previously saved only the display whose menu the toggle was flipped
    /// from, so switching on a global setting left every other display with
    /// nothing stored — protection that covered one display and silently missed
    /// the rest.
    private func saveConfigurationSnapshot() {
        let controller = DisplayController.shared
        let protection = ConfigProtectionController()
        let resolution = ResolutionController()
        for display in controller.displays where display.isOnline {
            protection.saveCurrentState(for: display, resolution: resolution, controller: controller)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $settingsTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch settingsTab {
            case .overview:
                overviewForm
            case .perDisplay:
                perDisplayList
            }
        }
    }

    /// The main settings form.
    private var overviewForm: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                Toggle("Show Rosetta warning", isOn: rosettaWarningBinding)
                Toggle("Show offline displays in Settings", isOn: showOfflineDisplaysBinding)
                Toggle("Enable connect/disconnect for displays", isOn: enableDisconnectOptionBinding)
                if hotkeysUnavailable {
                    Label("Media keys unavailable — allow Accessibility for FBD in System Settings", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("General", systemImage: "gearshape")
            }

            Section {
                HStack(spacing: FBDTheme.spacingM) {
                    Text("Cooldown between writes")
                    Spacer()
                    Stepper(value: cooldownBinding, in: 0...10_000, step: 100) {
                        Text("\(Settings.ddcCooldownMilliseconds) ms")
                            .monospacedDigit()
                    }
                }
                Text("Minimum delay between consecutive DDC/CI writes per display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("DDC / CI", systemImage: "cable.connector")
            }

            Section {
                Toggle("Combined brightness (hardware + XDR)", isOn: combinedBrightnessEnabled)
                Toggle("Software upscaling (Metal overlay)", isOn: softwareUpscalingEnabled)
                Text("Used when native XDR upscaling is unavailable. Requires Screen Recording permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Dim to black", isOn: dimToBlackEnabled)
                Text("Allows turning a display fully black.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Experimental direct color-table method", isOn: allowExperimentalDirectXDR)
                Text("Entitlement-gated on macOS 26+; has no effect there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: FBDTheme.spacingM) {
                    Text("XDR upscale target")
                    Spacer()
                    Stepper(value: xdrTarget, in: 100...1600, step: 100) {
                        Text("\(Settings.xdrUpscaleTargetNits) nits")
                            .monospacedDigit()
                    }
                }
            } header: {
                Label("XDR / HDR", systemImage: "sun.max.trianglebadge.exclamationmark")
            }

            Section {
                Toggle("Allow unsafe modes", isOn: unsafeModesBinding)
                Text("Allows applying modes outside the safe-mode flag set — experimental.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Experimental", systemImage: "flask")
            }

            Section {
                Toggle("Reconnect virtual screens after wake", isOn: reconnectOnWakeBinding)
                Toggle("Disconnect virtual screens while locked", isOn: disconnectOnLockBinding)
                Toggle("Auto-disconnect built-in when external connects", isOn: autoDisconnectBuiltInBinding)
                Text("Apple Silicon; experimental — screen goes dark while the external is connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if BuiltInDisconnectGuard.isAffectedHardware {
                    Text("This Mac (base M3) may not reconnect its built-in display without a reboot.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Toggle("Allow built-in display disconnect (risky)", isOn: allowBuiltInDisconnectBinding)
                }
                Toggle("Layout protection", isOn: layoutProtectionBinding)
                Text("Re-applies the saved arrangement when the display layout changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: FBDTheme.spacingM) {
                    Button("Save current arrangement") {
                        layoutProtection.saveCurrentArrangement()
                        hasSavedArrangement = layoutProtection.hasSavedArrangement
                    }
                    .controlSize(.small)
                    Button("Restore arrangement") {
                        _ = layoutProtection.restoreArrangement()
                    }
                    .controlSize(.small)
                    .disabled(!hasSavedArrangement)
                }

                // Moved here from the per-display menu. It is ONE global flag, and
                // in a display's own menu it read as an independent per-display
                // switch. It now also snapshots every display, where it previously
                // saved only the display whose menu it was flipped from — leaving
                // the others apparently protected with nothing stored.
                Toggle("Configuration protection", isOn: configProtectionBinding)
                Text("Saves each display's current mode, brightness and preset, and re-applies them when the display reconnects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Virtual Displays & Layout", systemImage: "rectangle.3.group")
            }

            Section {
                Toggle("Auto-apply saved EDID on connect", isOn: autoApplyEDIDOverrideBinding)
                Text("Re-applies a saved custom EDID whenever the display connects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Restore factory EDID on quit", isOn: restoreFactoryEDIDOnQuitBinding)
                Text("Reverts any active EDID override when FBD quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Config protection", isOn: configProtectionEnabledBinding)
                Text("Re-applies the saved resolution, preset and brightness when a display reconnects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("EDID & Protection", systemImage: "lock.shield")
            }

            Section {
                Toggle("HTTP API", isOn: httpAPIEnabledBinding)
                HStack(spacing: FBDTheme.spacingM) {
                    Text("Port")
                    Spacer()
                    Stepper(value: httpPortBinding, in: 1024...65535) {
                        Text("\(Settings.httpServerPort == 0 ? 1024 : Settings.httpServerPort)")
                            .monospacedDigit()
                    }
                }
                Text("Serves the control API on 127.0.0.1. Applies immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Custom OSD", isOn: customOSDBinding)
                Text("Shows a brightness HUD when the display brightness changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: FBDTheme.spacingM) {
                    Text("Night Shift strength")
                    Spacer()
                    Text("\(Int((nightShift.strength() ?? 0) * 100))%")
                        .monospacedDigit()
                }
                Slider(value: nightShiftStrengthBinding, in: 0...1)
                    .disabled(!nightShift.isAvailable)
                if !nightShift.isAvailable {
                    Text("Night Shift is unavailable on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if trueTone.isAvailable {
                    Toggle("True Tone", isOn: trueToneBinding)
                }
            } header: {
                Label("Integrations", systemImage: "network")
            }

            AutomationSettingsView()

            Section {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: FBDTheme.radiusTile, style: .continuous)
                        .fill(Color.accentColor.gradient)
                        .frame(width: 34, height: 34)
                        .overlay(
                            Image(systemName: "display")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("FBD — Free Better Display")
                            .font(.callout.weight(.medium))
                        Text("Version \(versionString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Link("GitHub — FisiFla/FBD", destination: URL(string: "https://github.com/FisiFla/FBD")!)
            } header: {
                Label("About", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        // Explicit saturated blue for the switch on-state so active toggles
        // are unmistakable against the material background.
        .tint(.blue)
        .navigationTitle("Settings")
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            hasSavedArrangement = layoutProtection.hasSavedArrangement
        }
        .onReceive(NotificationCenter.default.publisher(for: .fbdHotkeysUnavailable)) { _ in
            hotkeysUnavailable = true
        }
    }

    /// Per-display settings: one section per display (offline displays
    /// included when Settings.showOfflineDisplays is on).
    private var perDisplayList: some View {
        let displays = DisplayController.shared.displays
        let shown = Settings.showOfflineDisplays
            ? displays
            : displays.filter(\.isOnline)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: FBDTheme.spacingM) {
                    if shown.isEmpty {
                        Text("No displays")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 24)
                    }
                    // Display arrangement grid (System Settings-style drag to move).
                    ArrangementGridView()
                        .padding(.horizontal, 12)
                    ForEach(shown) { display in
                        perDisplayCard(display)
                            .padding(.horizontal, 12)
                            // Scroll target for a caller that asked Settings to
                            // reveal this display.
                            .id(display.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onAppear {
                guard let targetDisplayID,
                      shown.contains(where: { $0.id == targetDisplayID }) else { return }
                // One runloop turn, so the cards exist before we scroll to one.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    withAnimation(FBDTheme.animationFast) {
                        proxy.scrollTo(targetDisplayID, anchor: .top)
                    }
                }
            }
        }
    }

    private func perDisplayCard(_ display: Display) -> some View {
        PerDisplayCardView(display: display)
    }

    // MARK: - Bindings

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchAtLogin = newValue
                    Settings.launchAtLogin = newValue
                } catch {
                    log.error("Failed to update launch-at-login: \(error.localizedDescription)")
                    launchAtLogin = !newValue
                }
            }
        )
    }

    private var showOfflineDisplaysBinding: Binding<Bool> {
        Binding(
            get: { Settings.showOfflineDisplays },
            set: { Settings.showOfflineDisplays = $0 }
        )
    }

    private var enableDisconnectOptionBinding: Binding<Bool> {
        Binding(
            get: { Settings.enableDisconnectOption },
            set: { Settings.enableDisconnectOption = $0 }
        )
    }

    private var rosettaWarningBinding: Binding<Bool> {
        Binding(
            get: { Settings.showRosettaWarning },
            set: { Settings.showRosettaWarning = $0 }
        )
    }

    private var unsafeModesBinding: Binding<Bool> {
        Binding(
            get: { Settings.allowUnsafeInvalidModes },
            set: { Settings.allowUnsafeInvalidModes = $0 }
        )
    }

    private var cooldownBinding: Binding<Int> {
        Binding(
            get: { Settings.ddcCooldownMilliseconds },
            set: { Settings.ddcCooldownMilliseconds = max(0, $0) }
        )
    }

    private var combinedBrightnessEnabled: Binding<Bool> {
        Binding(
            get: { Settings.combinedBrightnessEnabled },
            set: { Settings.combinedBrightnessEnabled = $0 }
        )
    }

    private var softwareUpscalingEnabled: Binding<Bool> {
        Binding(
            get: { Settings.softwareUpscalingEnabled },
            set: { Settings.softwareUpscalingEnabled = $0 }
        )
    }

    private var dimToBlackEnabled: Binding<Bool> {
        Binding(
            get: { Settings.dimToBlackEnabled },
            set: { Settings.dimToBlackEnabled = $0 }
        )
    }

    private var allowExperimentalDirectXDR: Binding<Bool> {
        Binding(
            get: { Settings.allowExperimentalDirectXDR },
            set: { Settings.allowExperimentalDirectXDR = $0 }
        )
    }

    private var xdrTarget: Binding<Int> {
        Binding(
            get: { Settings.xdrUpscaleTargetNits },
            set: { Settings.xdrUpscaleTargetNits = $0 }
        )
    }

    private var reconnectOnWakeBinding: Binding<Bool> {
        Binding(
            get: { Settings.reconnectVirtualScreensOnWake },
            set: { Settings.reconnectVirtualScreensOnWake = $0 }
        )
    }

    private var disconnectOnLockBinding: Binding<Bool> {
        Binding(
            get: { Settings.disconnectVirtualScreensOnLock },
            set: { Settings.disconnectVirtualScreensOnLock = $0 }
        )
    }

    private var autoDisconnectBuiltInBinding: Binding<Bool> {
        Binding(
            get: { Settings.autoDisconnectBuiltInOnExternal },
            set: { Settings.autoDisconnectBuiltInOnExternal = $0 }
        )
    }

    private var allowBuiltInDisconnectBinding: Binding<Bool> {
        Binding(
            get: { Settings.allowBuiltInDisconnectOnAffectedMacs },
            set: { Settings.allowBuiltInDisconnectOnAffectedMacs = $0 }
        )
    }

    private var layoutProtectionBinding: Binding<Bool> {
        Binding(
            get: { Settings.layoutProtectionEnabled },
            set: { Settings.layoutProtectionEnabled = $0 }
        )
    }

    private var autoApplyEDIDOverrideBinding: Binding<Bool> {
        Binding(
            get: { Settings.autoApplyEDIDOverride },
            set: { Settings.autoApplyEDIDOverride = $0 }
        )
    }

    private var restoreFactoryEDIDOnQuitBinding: Binding<Bool> {
        Binding(
            get: { Settings.restoreFactoryEDIDOnQuit },
            set: { Settings.restoreFactoryEDIDOnQuit = $0 }
        )
    }

    private var configProtectionEnabledBinding: Binding<Bool> {
        Binding(
            get: { Settings.configProtectionEnabled },
            set: { Settings.configProtectionEnabled = $0 }
        )
    }

    private var httpAPIEnabledBinding: Binding<Bool> {
        Binding(
            get: { Settings.httpServerEnabled },
            set: { Settings.httpServerEnabled = $0 }
        )
    }

    private var httpPortBinding: Binding<Int> {
        Binding(
            get: { Settings.httpServerPort == 0 ? 1024 : Settings.httpServerPort },
            set: { Settings.httpServerPort = $0 }
        )
    }

    private var customOSDBinding: Binding<Bool> {
        Binding(
            get: { Settings.customOSDEnabled },
            set: { Settings.customOSDEnabled = $0 }
        )
    }

    private var nightShiftStrengthBinding: Binding<Double> {
        Binding(
            get: { nightShift.strength() ?? 0 },
            set: { _ = nightShift.setStrength($0) }
        )
    }

    private var trueToneBinding: Binding<Bool> {
        Binding(
            get: { trueTone.isEnabled() ?? false },
            set: { _ = trueTone.setEnabled($0) }
        )
    }

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}
