import CoreGraphics
import FBDCore
import SwiftUI

/// The per-display options menu (BetterDisplay-style): one ellipsis button
/// in the card header; the old quick-toggles row (HiDPI / Auto Brightness /
/// Notch) was folded in here and the dead Notch toggle removed.
///
/// Owns everything menu-only: the quick toggles, display mode / refresh /
/// color-mode / preset submenus, mirroring, PiP, rotation, configuration
/// protection and manage-display actions.
@MainActor
struct DisplayOptionsMenuView: View {
    @ObservedObject var display: Display
    /// Soft-disconnect confirmation flag — shared with the header power
    /// button, which carries the confirmation dialog.
    @Binding var confirmingDisable: Bool
    /// Bumped after actions that other views read back (color-profile
    /// application) so the row re-renders.
    @Binding var refreshTick: Int

    /// PiP / video-filter window controller (shared — one window process-wide).
    @State private var pipController = PipStreamController.shared
    /// Color profiles for the "Color Mode" submenu, loaded once per row
    /// appearance. (The profile picker in the sections view loads its own
    /// copy — both query ColorSync, so they stay in sync.)
    @State private var colorProfiles: [ColorProfile] = []
    @State private var colorProfilesLoaded = false
    @State private var colorProfileController = ColorProfileController()

    var body: some View {
        Menu {
            optionsMenuContent
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More options")
        .accessibilityLabel("More options for \(display.name)")
        .onAppear {
            loadColorProfilesIfNeeded()
        }
    }

    @ViewBuilder
    private var optionsMenuContent: some View {
        // Quick toggles
        Toggle("HiDPI", isOn: hidpiBinding)
            .help("Switch between the HiDPI and standard variant of the current resolution")
        if autoBrightnessAvailable {
            Toggle("Auto Brightness", isOn: autoBrightnessBinding)
                .help("Ambient-light compensation (hardware)")
        }
        Divider()

        // Display Mode
        Menu("Display Mode") {
            ForEach(display.modes, id: \.self) { mode in
                Button {
                    DisplayController.shared.applyMode(mode, to: display)
                } label: {
                    if mode == display.currentMode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        }

        // Refresh Rate
        if !refreshRates.isEmpty {
            Menu("Refresh Rate") {
                ForEach(refreshRates, id: \.self) { hz in
                    Button {
                        applyRefreshRate(hz)
                    } label: {
                        if hz == display.currentMode?.refreshRate {
                            Label(String(format: "%.0f Hz", hz), systemImage: "checkmark")
                        } else {
                            Text(String(format: "%.0f Hz", hz))
                        }
                    }
                }
            }
        }

        // Color Mode (color profiles)
        if !colorProfiles.isEmpty {
            Menu("Color Mode") {
                ForEach(colorProfiles) { profile in
                    Button {
                        if colorProfileController.applyProfile(profile.url, for: display) {
                            refreshTick += 1
                        }
                    } label: {
                        if colorProfileController.defaultProfile(for: display) == profile.url {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            }
        }

        // Apple Display Preset (XDR presets)
        if !validPresets.isEmpty {
            Menu("Apple Display Preset") {
                ForEach(validPresets) { preset in
                    Button {
                        DisplayController.shared.selectPreset(preset.index, on: display)
                    } label: {
                        if display.activePresetIndex == preset.index {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            }
        }

        Divider()

        // Mirror Display
        Menu("Mirror Display") {
            if CGDisplayIsInMirrorSet(display.id) != 0 {
                Button("Unmirror") {
                    unmirrorDisplay()
                }
                Divider()
            }
            ForEach(mirrorTargets) { target in
                Button(target.name) {
                    mirror(to: target)
                }
            }
        }

        // Picture in Picture (the old "Stream Display" twin was removed —
        // both called the same function).
        Button("Picture in Picture") {
            startVideoFilterWindow()
        }

        // Move Display
        Menu("Move Display") {
            Button("Set as Main Display") {
                _ = DisplayController.shared.setAsMainDisplay(display)
            }
            Text("Arrange displays from the Settings per-display tab")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        // Screen Rotation
        Menu("Screen Rotation") {
            ForEach([0, 90, 180, 270], id: \.self) { angle in
                Button("\(angle)°") {
                    _ = DisplayController.shared.setRotation(angle, on: display)
                }
            }
        }

        // Configuration Protection
        Toggle("Configuration Protection", isOn: configProtectionBinding)
            .help("Re-apply this display's saved mode/brightness/preset on reconnect")

        // Manage Display
        Menu("Manage Display") {
            if Settings.enableDisconnectOption {
                if display.isOnline {
                    Button(role: .destructive) {
                        confirmingDisable = true
                    } label: {
                        Label("Disable display", systemImage: "power")
                    }
                } else {
                    Button("Re-enable display") {
                        _ = DisconnectController().setEnabled(true, displayID: display.id)
                    }
                }
            }
            Button("Show in Settings") {
                NotificationCenter.default.post(name: .fbdOpenSettings, object: nil)
            }
        }
    }

    // MARK: - Quick control helpers

    private var hidpiBinding: Binding<Bool> {
        Binding(
            get: { display.currentMode?.isHiDPI ?? false },
            set: { wantHiDPI in
                guard let current = display.currentMode else { return }
                let candidate = display.modes.first {
                    $0.width == current.width && $0.height == current.height
                        && $0.refreshRate == current.refreshRate
                        && $0.isHiDPI == wantHiDPI
                }
                if let candidate {
                    DisplayController.shared.applyMode(candidate, to: display)
                }
            }
        )
    }

    private var autoBrightnessAvailable: Bool {
        DisplayController.shared.isAmbientLightCompensationEnabled(on: display) != nil
    }

    private var autoBrightnessBinding: Binding<Bool> {
        Binding(
            get: { DisplayController.shared.isAmbientLightCompensationEnabled(on: display) ?? false },
            set: { DisplayController.shared.setAmbientLightCompensation($0, on: display) }
        )
    }

    private var configProtectionBinding: Binding<Bool> {
        Binding(
            get: { Settings.configProtectionEnabled },
            set: { on in
                Settings.configProtectionEnabled = on
                if on {
                    ConfigProtectionController().saveCurrentState(
                        for: display,
                        resolution: ResolutionController(),
                        controller: DisplayController.shared
                    )
                }
            }
        )
    }

    /// Unique refresh rates from the display's modes, ascending.
    private var refreshRates: [Double] {
        let rates = Set(display.modes.map(\.refreshRate))
        return rates.sorted()
    }

    private func applyRefreshRate(_ hz: Double) {
        guard let current = display.currentMode else { return }
        let candidate = display.modes.first {
            $0.width == current.width && $0.height == current.height
                && $0.refreshRate == hz && $0.isHiDPI == current.isHiDPI
        }
        if let candidate {
            DisplayController.shared.applyMode(candidate, to: display)
        }
    }

    /// Other online displays available as mirror targets.
    private var mirrorTargets: [Display] {
        DisplayController.shared.displays.filter { $0.id != display.id && $0.isOnline }
    }

    /// Mirror this display onto a target by creating (or reusing) a group
    /// containing exactly the two displays, then mirroring the group.
    private func mirror(to target: Display) {
        let groups = DisplayGroupsController()
        if let existing = groups.groups.first(where: {
            $0.displayIDs == [display.id, target.id] || $0.displayIDs == [target.id, display.id]
        }) {
            _ = groups.mirror(inGroup: existing.id)
            return
        }
        groups.createGroup(name: "Mirror \(display.name) → \(target.name)", displayIDs: [display.id, target.id])
        if let group = groups.groups.last {
            _ = groups.mirror(inGroup: group.id)
        }
    }

    private func unmirrorDisplay() {
        let groups = DisplayGroupsController()
        for group in groups.groups where group.displayIDs.contains(display.id) {
            _ = groups.unmirror(inGroup: group.id)
        }
    }

    /// Start the floating video-filter (PiP) window for this display.
    private func startVideoFilterWindow() {
        _ = pipController.startPiP(displayID: display.id, filter: .identity)
    }

    private var validPresets: [XDRPreset] {
        display.presets.filter { $0.isValid }
    }

    /// Load profiles once per row appearance; empty result keeps the
    /// "Color Mode" submenu hidden.
    private func loadColorProfilesIfNeeded() {
        guard !colorProfilesLoaded else { return }
        colorProfilesLoaded = true
        colorProfiles = colorProfileController.profiles(for: display)
    }
}
