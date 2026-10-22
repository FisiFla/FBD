import FBDCore
import os
import ServiceManagement
import SwiftUI

/// App-level settings: launch, updates, the brightness model, integrations and
/// automation.
@MainActor
struct ApplicationSettingsPage: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Re-renders this page when a setting changes (`Settings` is not observable); also carries
    /// the latched hotkeys-unavailable flag.
    @ObservedObject private var settingsObserver = SettingsObserver.shared
    @State private var nightShift = NightShiftController()
    @State private var trueTone = TrueToneController()
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "App")

    var body: some View {
        SettingsPane("Application") {
            SettingsGroup {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                Toggle("Show Rosetta warning", isOn: bool(Settings.showRosettaWarning) { Settings.showRosettaWarning = $0 })
                Toggle("Enable connect/disconnect for displays", isOn: bool(Settings.enableDisconnectOption) { Settings.enableDisconnectOption = $0 })
                if settingsObserver.hotkeysUnavailable {
                    Label("Media keys unavailable — allow Accessibility for FBD in System Settings", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("General", systemImage: "gearshape")
            }

            SettingsGroup {
                OSDStyleSection()
            } header: {
                Label("On-screen display", systemImage: "rectangle.on.rectangle")
            }

            SettingsGroup {
                Toggle("Show FBD in the Dock", isOn: bool(Settings.showDockIcon) { Settings.showDockIcon = $0 })
                Toggle("Brief Dock icon at launch", isOn: bool(Settings.briefDockIconAtStartup) { Settings.briefDockIconAtStartup = $0 })
                Text("A menu-bar app normally has no Dock icon. These make it findable there — permanently, or only just after it opens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Dock", systemImage: "app.dock")
            }

            brightnessModelSection
            brightnessSection
            lockDimSection

            SettingsGroup {
                SettingsRow(
                    title: "Cooldown between writes",
                    caption: "Minimum delay between consecutive DDC/CI writes per display."
                ) {
                    Stepper(value: int(Settings.ddcCooldownMilliseconds) { Settings.ddcCooldownMilliseconds = max(0, $0) }, in: 0...10_000, step: 100) {
                        Text("\(Settings.ddcCooldownMilliseconds) ms").monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("DDC/CI cooldown")
                    .accessibilityValue("\(Settings.ddcCooldownMilliseconds) milliseconds")
                }
            } header: {
                Label("DDC / CI", systemImage: "cable.connector")
            }

            SettingsGroup {
                Toggle("HTTP API", isOn: bool(Settings.httpServerEnabled) { Settings.httpServerEnabled = $0 })
                SettingsRow(
                    title: "Port",
                    caption: "Serves the control API on 127.0.0.1. Applies immediately."
                ) {
                    Stepper(value: int(Settings.httpServerPort == 0 ? 1024 : Settings.httpServerPort) { Settings.httpServerPort = $0 }, in: 1024...65535) {
                        Text("\(Settings.httpServerPort == 0 ? 1024 : Settings.httpServerPort)").monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("HTTP port")
                    .accessibilityValue("\(Settings.httpServerPort == 0 ? 1024 : Settings.httpServerPort)")
                }
                SettingsSliderRow(
                    title: "Night Shift strength",
                    value: nightShift.strength() ?? 0,
                    range: 0...1,
                    format: { "\(Int($0 * 100))%" },
                    caption: nightShift.isAvailable ? nil : "Night Shift is unavailable on this Mac.",
                    onChange: { _ = nightShift.setStrength($0) }
                )
                if trueTone.isAvailable {
                    Toggle("True Tone", isOn: trueToneBinding)
                }
                if DarkModeController().isAvailable {
                    Toggle("Dark Mode", isOn: darkModeBinding)
                    Text("The system appearance — the switch Control Center flips, so another app can change it too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Integrations", systemImage: "network")
            }

            SettingsGroup {
                Toggle("Allow unsafe modes", isOn: bool(Settings.allowUnsafeInvalidModes) { Settings.allowUnsafeInvalidModes = $0 })
                Text("Allows applying modes outside the safe-mode flag set — experimental.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Reconnect virtual screens after wake", isOn: bool(Settings.reconnectVirtualScreensOnWake) { Settings.reconnectVirtualScreensOnWake = $0 })
                Toggle("Disconnect virtual screens while locked", isOn: bool(Settings.disconnectVirtualScreensOnLock) { Settings.disconnectVirtualScreensOnLock = $0 })
                Toggle("Auto-disconnect built-in when external connects", isOn: bool(Settings.autoDisconnectBuiltInOnExternal) { Settings.autoDisconnectBuiltInOnExternal = $0 })
                Text("Apple Silicon; experimental — screen goes dark while the external is connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Turn off the built-in display while an external display is attached", isOn: dockedBuiltInBinding)
                Text("Turns the built-in display off while an external display is attached, so you work on the external screen. Refused on Macs where the built-in display may not come back without a reboot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if BuiltInDisconnectGuard.isAffectedHardware {
                    Text("This Mac (base M3) may not reconnect its built-in display without a reboot.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Toggle("Allow built-in display disconnect (risky)", isOn: bool(Settings.allowBuiltInDisconnectOnAffectedMacs) { Settings.allowBuiltInDisconnectOnAffectedMacs = $0 })
                }
                Toggle("Layout protection", isOn: bool(Settings.layoutProtectionEnabled) { Settings.layoutProtectionEnabled = $0 })
                Text("Re-applies the saved arrangement when the display layout changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Virtual Displays & Layout", systemImage: "rectangle.3.group")
            }

            SettingsGroup {
                Toggle("Auto-apply saved EDID on connect", isOn: bool(Settings.autoApplyEDIDOverride) { Settings.autoApplyEDIDOverride = $0 })
                Text("Re-applies a saved custom EDID whenever the display connects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Restore factory EDID on quit", isOn: bool(Settings.restoreFactoryEDIDOnQuit) { Settings.restoreFactoryEDIDOnQuit = $0 })
                Text("Reverts any active EDID override when FBD quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Configuration protection", isOn: configProtectionBinding)
                Text("Saves each display's selected properties and re-applies them when the display reconnects. Choose the properties per display under Displays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Hold ⇧ Shift while launching, or set FBD_SAFE_MODE=1, to skip applying stored configuration for one session — the escape hatch after a bad EDID override.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("EDID & Protection", systemImage: "lock.shield")
            }

            AutomationSettingsView()
        }
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    // MARK: Brightness model

    /// The knobs that shape the combined-brightness curve. Global rather than
    /// per-display, because they describe the model, not one monitor.
    private var brightnessModelSection: some View {
        SettingsGroup {
            Toggle("Prefer hardware brightness control", isOn: prefs(\.preferHardwareControl))
            Text("When off, brightness is reached through software dimming rather than the display's own backlight.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SettingsRow(title: "Hardware minimum", caption: "Peak brightness in nits when the hardware control is at its minimum.") {
                Stepper(value: doublePref(\.hardwareMinNits, step: 1, range: 0...40_000), in: 0...40_000, step: 1) {
                    Text("\(Int(Settings.brightnessPreferences.hardwareMinNits)) nits").monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Hardware minimum")
                .accessibilityValue("\(Int(Settings.brightnessPreferences.hardwareMinNits)) nits")
            }
            SettingsRow(title: "Hardware maximum", caption: "Peak brightness in nits when the hardware control is at its maximum.") {
                Stepper(value: doublePref(\.hardwareMaxNits, step: 50, range: 0...40_000), in: 0...40_000, step: 50) {
                    Text("\(Int(Settings.brightnessPreferences.hardwareMaxNits)) nits").monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Hardware maximum")
                .accessibilityValue("\(Int(Settings.brightnessPreferences.hardwareMaxNits)) nits")
            }
            SettingsRow(title: "HDR peak SDR", caption: "Peak SDR brightness in HDR mode.") {
                Stepper(value: doublePref(\.hdrPeakSDRNits, step: 50, range: 0...40_000), in: 0...40_000, step: 50) {
                    Text("\(Int(Settings.brightnessPreferences.hdrPeakSDRNits)) nits").monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("HDR peak SDR")
                .accessibilityValue("\(Int(Settings.brightnessPreferences.hdrPeakSDRNits)) nits")
            }
            SettingsRow(title: "HDR peak HDR", caption: "Peak HDR brightness.") {
                Stepper(value: doublePref(\.hdrPeakHDRNits, step: 50, range: 0...40_000), in: 0...40_000, step: 50) {
                    Text("\(Int(Settings.brightnessPreferences.hdrPeakHDRNits)) nits").monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("HDR peak HDR")
                .accessibilityValue("\(Int(Settings.brightnessPreferences.hdrPeakHDRNits)) nits")
            }

            SettingsSliderRow(
                title: "Redefine 0% software brightness",
                value: Settings.brightnessPreferences.softwareZeroPercent,
                range: 0...100,
                format: { "\(Int($0))%" },
                caption: "Compresses the usable software range so 0% is not absolute black.",
                onChange: { doublePref(\.softwareZeroPercent).wrappedValue = $0 }
            )
            SettingsSliderRow(
                title: "Minimum hardware level",
                value: Settings.brightnessPreferences.minHardwarePercent,
                range: 0...100,
                format: { "\(Int($0))%" },
                caption: "The lowest hardware brightness value before software dimming takes over.",
                onChange: { doublePref(\.minHardwarePercent).wrappedValue = $0 }
            )
            SettingsSliderRow(
                title: "Software dimming switchover",
                value: Settings.brightnessPreferences.dimmingSwitchoverPercent,
                range: 0...100,
                format: { "\(Int($0))%" },
                caption: "Below this point on the combined scale, extra software dimming is applied.",
                onChange: { doublePref(\.dimmingSwitchoverPercent).wrappedValue = $0 }
            )
            SettingsSliderRow(
                title: "Upscaling maximum",
                value: Settings.brightnessPreferences.upscaleMaxPercent,
                range: 100...1000,
                format: { "\(Int($0))%" },
                caption: "The top of the XDR/HDR upscaling range on the combined scale.",
                onChange: { doublePref(\.upscaleMaxPercent).wrappedValue = $0 }
            )

            Picker("Stored control values on startup", selection: policyPrefBinding) {
                ForEach(StartupControlValuePolicy.allCases, id: \.self) { policy in
                    Text(label(for: policy)).tag(policy)
                }
            }
            Text("Whether stored control values are assumed valid, written to the device, or read back at startup.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("Brightness model", systemImage: "slider.horizontal.below.sun.max")
        }
    }

    private var brightnessSection: some View {
        SettingsGroup {
            Toggle("Combined brightness (hardware + XDR)", isOn: bool(Settings.combinedBrightnessEnabled) { Settings.combinedBrightnessEnabled = $0 })
            Toggle("Software upscaling (Metal overlay)", isOn: bool(Settings.softwareUpscalingEnabled) { Settings.softwareUpscalingEnabled = $0 })
            Text("Used when native XDR upscaling is unavailable. Requires Screen Recording permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Dim to black", isOn: bool(Settings.dimToBlackEnabled) { Settings.dimToBlackEnabled = $0 })
            Text("Allows turning a display fully black.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Experimental direct color-table method", isOn: bool(Settings.allowExperimentalDirectXDR) { Settings.allowExperimentalDirectXDR = $0 })
            Text("Entitlement-gated on macOS 26+; has no effect there.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SettingsRow(title: "XDR upscale target") {
                Stepper(value: int(Settings.xdrUpscaleTargetNits) { Settings.xdrUpscaleTargetNits = $0 }, in: 100...1600, step: 100) {
                    Text("\(Settings.xdrUpscaleTargetNits) nits").monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("XDR upscale target")
                .accessibilityValue("\(Settings.xdrUpscaleTargetNits) nits")
            }
        } header: {
            Label("XDR / HDR", systemImage: "sun.max.trianglebadge.exclamationmark")
        }
    }

    private var lockDimSection: some View {
        SettingsGroup {
            Toggle("Dim display on screen saver or lock", isOn: bool(Settings.lockDimEnabled) { Settings.lockDimEnabled = $0 })
            Text("Screen brightness is lowered while the screen is locked or the screensaver is up, and restored on unlock.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SettingsSliderRow(
                title: "Dim to",
                value: Settings.lockDimTargetPercent,
                range: 0...100,
                format: { "\(Int($0))%" },
                caption: "Brightness the display is reduced to while locked.",
                onChange: { Settings.lockDimTargetPercent = $0 }
            )
        } header: {
            Label("Lock dim", systemImage: "lock.display")
        }
    }

    private func label(for policy: StartupControlValuePolicy) -> String {
        switch policy {
        case .assumeLastUsed: return "Assume last used or default values are valid"
        case .writeToDevice: return "Write last used values to the device"
        case .readFromDevice: return "Read values from the device"
        }
    }

    // MARK: Bindings

    private var configProtectionBinding: Binding<Bool> {
        Binding(
            get: { Settings.configProtectionEnabled },
            set: { enabled in
                Settings.configProtectionEnabled = enabled
                guard enabled else { return }
                // Snapshot every online display, so switching the global setting
                // on protects all of them rather than only one.
                let controller = DisplayController.shared
                let protection = ConfigProtectionController()
                let resolution = ResolutionController()
                for display in controller.displays where display.isOnline {
                    protection.saveCurrentState(for: display, resolution: resolution, controller: controller)
                }
            }
        )
    }

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

    /// Dark Mode belongs to the *system*, so this binding reads it live instead of caching it: the
    /// value can change underneath us — Control Center, another app — and a remembered copy would
    /// have the toggle reporting stale state until something forced a redraw. The controller holds
    /// no state of its own, so one per access is free.
    private var darkModeBinding: Binding<Bool> {
        Binding(
            get: { DarkModeController().isDark() ?? false },
            set: { _ = DarkModeController().setDark($0) }
        )
    }

    /// True Tone lives on a MainActor-isolated controller, so it needs its own
    /// binding rather than the `bool`/`int` helpers above.
    private var trueToneBinding: Binding<Bool> {
        Binding(
            get: { trueTone.isEnabled() ?? false },
            set: { _ = trueTone.setEnabled($0) }
        )
    }

    /// The docked built-in display.
    ///
    /// Its own binding, because turning it on can be refused: on a base-M3
    /// MacBook the built-in panel may not come back without a reboot, and the
    /// refusal is said out loud rather than leaving a switch that does
    /// nothing.
    private var dockedBuiltInBinding: Binding<Bool> {
        Binding(
            get: { Settings.dockedBuiltInOffEnabled },
            set: { on in
                Settings.dockedBuiltInOffEnabled = on
                guard on, !BuiltInDisconnectGuard.builtInDisconnectAllowed else { return }
                FBDNotice.shared.report(
                    String(localized: "This Mac (base M3) may not reconnect its built-in display without a reboot.")
                )
            }
        )
    }

    private func bool(_ get: @autoclosure @escaping @Sendable () -> Bool, set: @escaping @Sendable (Bool) -> Void) -> Binding<Bool> {
        Binding(get: get, set: set)
    }

    private func int(_ get: @autoclosure @escaping @Sendable () -> Int, set: @escaping @Sendable (Int) -> Void) -> Binding<Int> {
        Binding(get: get, set: set)
    }

    // MARK: Brightness-preferences bindings

    /// Reads and writes one preference through the JSON blob, so every control
    /// goes through the single `Settings.defaults` write path.
    private func prefs(_ key: WritableKeyPath<BrightnessPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { Settings.brightnessPreferences[keyPath: key] },
            set: { value in
                var current = Settings.brightnessPreferences
                current[keyPath: key] = value
                Settings.brightnessPreferences = current
            }
        )
    }

    private func doublePref(
        _ key: WritableKeyPath<BrightnessPreferences, Double>,
        step: Double = 0,
        range: ClosedRange<Double>? = nil
    ) -> Binding<Double> {
        Binding(
            get: { Settings.brightnessPreferences[keyPath: key] },
            set: { value in
                var current = Settings.brightnessPreferences
                var next = value
                if let range { next = min(max(next, range.lowerBound), range.upperBound) }
                current[keyPath: key] = next
                Settings.brightnessPreferences = current
            }
        )
    }

    private var policyPrefBinding: Binding<StartupControlValuePolicy> {
        Binding(
            get: { Settings.brightnessPreferences.startupControlValuePolicy },
            set: { value in
                var current = Settings.brightnessPreferences
                current.startupControlValuePolicy = value
                Settings.brightnessPreferences = current
            }
        )
    }
}
