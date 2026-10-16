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
    /// Resolution controller backing the favourite slots and the presets in the menu.
    @State private var favouriteResolution = ResolutionController()

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
            // Offered modes, not the raw list: the options come from Settings, so
            // "Allow unsafe modes" changes what appears here too.
            ForEach(display.offeredModes, id: \.self) { mode in
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

        // Resolution favourites — five recall slots, the panel's analogue of
        // BetterDisplay's per-display favourite modes. Each slot is its own
        // submenu so the recorded mode is visible before applying it.
        Menu("Resolution Favourites") {
            ForEach(1...ModeFavourites.slotCount, id: \.self) { slot in
                Menu(favouriteSlotLabel(slot)) {
                    if let favourite = ModeFavourites.favourite(slot: slot, for: display.identityKey) {
                        Button("Apply \(DisplayOptionActions.favouriteSummary(favourite))") {
                            DisplayOptionActions.applyFavourite(slot, to: display, using: favouriteResolution)
                            refreshTick += 1
                        }
                        Divider()
                    }
                    Button("Record current resolution") {
                        if DisplayOptionActions.recordFavourite(slot, for: display, using: favouriteResolution) {
                            refreshTick += 1
                        }
                    }
                }
            }
        }

        // Display presets — a whole configuration saved under a name. This is
        // the panel's quick way to apply one; naming and deleting them lives in
        // Settings → Displays.
        Menu("Display Presets") {
            let presets = DisplayPresets.presets(for: display.identityKey)
            if presets.isEmpty {
                Button("No presets saved.") {}
                    .disabled(true)
            } else {
                ForEach(presets) { preset in
                    Button {
                        applyPreset(preset)
                    } label: {
                        Label(preset.name, systemImage: preset.symbol.symbolName)
                    }
                }
            }
        }

        Divider()
        // mirror onto, and the menu opened empty — a dead affordance. Disable it
        // and say why instead.
        Menu("Mirror Display") {
            if DisplayOptionActions.isMirrored(display) {
                Button("Unmirror") {
                    DisplayOptionActions.unmirror(display)
                }
                Divider()
            }
            ForEach(mirrorTargets) { target in
                Button(target.name) {
                    DisplayOptionActions.mirror(display, onto: target)
                }
            }
        }
        .disabled(mirrorTargets.isEmpty && !DisplayOptionActions.isMirrored(display))
        .help(mirrorTargets.isEmpty
              ? "Connect another display to mirror onto"
              : "Mirror this display onto another display")

        // Picture in Picture (the old "Stream Display" twin was removed —
        // both called the same function).
        Button("Picture in Picture") {
            DisplayOptionActions.startPictureInPicture(of: display)
        }

        // Local streaming: redirect this display onto another one, full-screen.
        // Same target set as mirroring — the other online displays.
        if !mirrorTargets.isEmpty {
            Menu("Stream to") {
                ForEach(mirrorTargets, id: \.id) { target in
                    Button(target.name) {
                        DisplayOptionActions.stream(display, to: target)
                    }
                }
            }
        }
        if pipController.isActive {
            Button("Stop PiP / Stream") {
                pipController.stop()
            }
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
                    // Rotation genuinely fails on displays that do not support it
                    // (both of this project's own displays refuse it), and the
                    // result used to be discarded, so the menu item closed and
                    // looked dead.
                    if DisplayController.shared.setRotation(angle, on: display) == nil {
                        FBDNotice.shared.report(String(localized: "This display would not rotate to \(angle)°."))
                    }
                }
            }
        }

        // Configuration Protection used to live here, as a per-display toggle over
        // one GLOBAL flag: it read as an independent per-display switch while
        // enabling it saved only this display. It is in Settings now, where its
        // scope is unambiguous and it snapshots every display.

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
            // This used to promise navigation it never performed: it posted no
            // payload and SettingsView had no target-display concept at all, so
            // the menu closed and you landed on the Overview page. It now opens
            // the Per-Display tab and scrolls to this display.
            Button("Show in Settings") {
                DisplayOptionActions.showInSettings(display)
            }
        }
    }

    // MARK: - Quick control helpers

    /// The label for one favourite slot: the recorded mode, or "empty".
    private func favouriteSlotLabel(_ slot: Int) -> String {
        guard let favourite = ModeFavourites.favourite(slot: slot, for: display.identityKey) else {
            return "\(slot) — empty"
        }
        return "\(slot) — \(DisplayOptionActions.favouriteSummary(favourite))"
    }

    /// Applies a named preset and says what actually happened: a preset can name
    /// properties this display cannot report, and passing those off as applied
    /// would be the one thing worse than not restoring them.
    private func applyPreset(_ preset: DisplayPreset) {
        let outcome = DisplayPresetApplier.apply(
            preset,
            to: display,
            resolution: favouriteResolution,
            controller: DisplayController.shared
        )
        if outcome.applied.isEmpty && !outcome.requested.isEmpty {
            FBDNotice.shared.report(String(localized: "Nothing in '\(preset.name)' applies to this display."))
        } else if outcome.unavailable.isEmpty {
            FBDNotice.shared.report(String(localized: "Applied '\(preset.name)'."))
        } else {
            FBDNotice.shared.report(String(
                localized: "Applied '\(preset.name)' — skipped \(outcome.unavailable.names.joined(separator: ", "))."
            ))
        }
        refreshTick += 1
    }

    private var hidpiBinding: Binding<Bool> {
        Binding(
            get: { display.currentMode?.isHiDPI ?? false },
            set: { DisplayOptionActions.setHiDPI($0, on: display) }
        )
    }

    private var autoBrightnessAvailable: Bool {
        DisplayOptionActions.autoBrightness(of: display) != nil
    }

    private var autoBrightnessBinding: Binding<Bool> {
        Binding(
            get: { DisplayOptionActions.autoBrightness(of: display) ?? false },
            set: { DisplayOptionActions.setAutoBrightness($0, on: display) }
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

    /// Other online displays available as mirror or stream targets.
    private var mirrorTargets: [Display] {
        DisplayOptionActions.mirrorTargets(for: display)
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
