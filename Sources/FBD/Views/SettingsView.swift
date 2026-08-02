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
    @State private var layoutProtection = LayoutProtectionController()
    @State private var hasSavedArrangement = false
    @State private var nightShift = NightShiftController()
    @State private var trueTone = TrueToneController()
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "App")

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                Toggle("Show Rosetta warning", isOn: rosettaWarningBinding)
            }

            Section("DDC") {
                HStack(spacing: 8) {
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
            }

            Section("XDR / HDR") {
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
                HStack(spacing: 8) {
                    Text("XDR upscale target")
                    Spacer()
                    Stepper(value: xdrTarget, in: 100...1600, step: 100) {
                        Text("\(Settings.xdrUpscaleTargetNits) nits")
                            .monospacedDigit()
                    }
                }
            }

            Section("Experimental") {
                Toggle("Allow unsafe modes", isOn: unsafeModesBinding)
                Text("Allows applying modes outside the safe-mode flag set — experimental.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Virtual Displays & Layout") {
                Toggle("Reconnect virtual screens after wake", isOn: reconnectOnWakeBinding)
                Toggle("Disconnect virtual screens while locked", isOn: disconnectOnLockBinding)
                Toggle("Auto-disconnect built-in when external connects", isOn: autoDisconnectBuiltInBinding)
                Text("Apple Silicon; experimental — screen goes dark while the external is connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Layout protection", isOn: layoutProtectionBinding)
                Text("Re-applies the saved arrangement when the display layout changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
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
            }

            Section("EDID & Protection") {
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
            }

            Section("Integrations") {
                Toggle("HTTP API", isOn: httpAPIEnabledBinding)
                HStack(spacing: 8) {
                    Text("Port")
                    Spacer()
                    Stepper(value: httpPortBinding, in: 1024...65535) {
                        Text("\(Settings.httpServerPort == 0 ? 1024 : Settings.httpServerPort)")
                            .monospacedDigit()
                    }
                }
                Text("Serves the control API on 127.0.0.1. Restart the app to apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Custom OSD", isOn: customOSDBinding)
                Text("Shows a brightness HUD when the display brightness changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
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
            }

            Section("About") {
                LabeledContent("Version", value: versionString)
                Link("GitHub — FisiFla/FBD", destination: URL(string: "https://github.com/FisiFla/FBD")!)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            hasSavedArrangement = layoutProtection.hasSavedArrangement
        }
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
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}
