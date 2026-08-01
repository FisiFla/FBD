import FBDCore
import os
import ServiceManagement
import SwiftUI

/// Settings panel: launch at login, DDC cooldown, Rosetta warning toggle,
/// experimental unsafe modes, and an About section.
@MainActor
struct SettingsView: View {
    var onDone: () -> Void = {}

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
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

            Section("About") {
                LabeledContent("Version", value: versionString)
                Link("GitHub — FisiFla/FBD", destination: URL(string: "https://github.com/FisiFla/FBD")!)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    onDone()
                }
            }
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
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

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}
