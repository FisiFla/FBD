import FBDCore
import os
import SwiftUI

// MARK: - Displays

/// The long per-display page: the arrangement grid, the connection-management
/// actions, and one card per display carrying that display's own settings.
@MainActor
struct DisplaySettingsPage: View {
    /// Re-renders this page when a setting changes (`Settings` is not observable).
    @ObservedObject private var settingsObserver = SettingsObserver.shared
    let targetDisplayID: CGDirectDisplayID?

    @State private var layoutProtection = LayoutProtectionController()
    @State private var hasSavedArrangement = false
    @State private var disconnect = DisconnectController()
    @State private var lastConnectionResult: String?
    @State private var confirmingDisconnectAll = false

    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "Settings")

    var body: some View {
        let displays = DisplayController.shared.displays
        let shown = Settings.showOfflineDisplays ? displays : displays.filter(\.isOnline)

        return ScrollViewReader { proxy in
            SettingsPane("Displays") {
                if shown.isEmpty {
                    SettingsGroup {
                        Text("No displays")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsGroup {
                    ArrangementGridView()
                } header: {
                    Label("Arrangement", systemImage: "rectangle.3.group")
                }

                edgeCrossingSection

                connectionManagementSection(displays)

                ForEach(shown) { display in
                    // The scroll target for `targetDisplayID` lives on this card's first row.
                    PerDisplayCardView(display: display)
                    DisplayProtectionSection(display: display)
                    DisplayFavouritesSection(display: display)
                    DisplayPresetsSection(display: display)
                }
            }
                .onAppear {
                hasSavedArrangement = layoutProtection.hasSavedArrangement
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

    /// Bulk connect/disconnect, planned by the pure `ConnectionPlanner` and
    /// executed through the guarded `DisconnectController` chokepoint.
    private func connectionManagementSection(_ displays: [Display]) -> some View {
        SettingsGroup {
            HStack(spacing: FBDTheme.spacingM) {
                Button("Connect all") { run(.connectAll, displays) }
                    .controlSize(.small)
                Button("Disconnect all but main") { confirmingDisconnectAll = true }
                    .controlSize(.small)
                Button("Save arrangement") {
                    layoutProtection.saveCurrentArrangement()
                    hasSavedArrangement = layoutProtection.hasSavedArrangement
                }
                .controlSize(.small)
                Button("Restore arrangement") { _ = layoutProtection.restoreArrangement() }
                    .controlSize(.small)
                    .disabled(!hasSavedArrangement)
            }

            if let lastConnectionResult {
                Text(lastConnectionResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Connection management", systemImage: "cable.connector")
        } footer: {
            Text("Disconnecting a display turns it off until it is re-enabled. The built-in display is never disconnected on Macs where it may not come back without a reboot.")
                .fbdLeadingFooter()
        }
        .fbdConfirmation(
            "Disconnect all but the main display?",
            isPresented: $confirmingDisconnectAll,
            confirm: "Disconnect",
            message: "Every other display turns off until it is re-enabled."
        ) {
            run(.disconnectAllButMain, displays)
        }
    }

    /// Pointer crossing between displays whose edges do not line up (Crisp item 9).
    ///
    /// A plain toggle over a stored preference: the controller's own timer picks
    /// the change up, so there is nothing to start or stop here.
    private var edgeCrossingSection: some View {
        SettingsGroup {
            Toggle(
                "Cross misaligned display edges",
                isOn: bool(Settings.edgeCrossingEnabled) { Settings.edgeCrossingEnabled = $0 }
            )
        } footer: {
            Text("Lets the pointer move between displays whose edges do not line up, instead of stopping at the gap.")
                .fbdLeadingFooter()
        }
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

    private func run(_ action: ConnectionAction, _ displays: [Display]) {
        let descriptors = displays.map { display in
            DisplayDescriptor(
                displayID: display.id,
                isOnline: display.isOnline,
                isBuiltin: display.isBuiltin,
                isMain: CGDisplayIsMain(display.id) != 0,
                vendor: display.vendorNumber,
                model: display.modelNumber,
                serial: display.serialNumber
            )
        }
        let steps = ConnectionPlanner.plan(
            action: action,
            displays: descriptors,
            allowsAffectedBuiltInDisconnect: Settings.allowBuiltInDisconnectOnAffectedMacs
        )
        if steps.isEmpty && action == .disconnectAllButMain {
            lastConnectionResult = String(localized: "No main display — nothing to do.")
            return
        }
        let applied = disconnect.apply(steps)
        lastConnectionResult = String(localized: "\(applied) of \(steps.count) display(s) changed.")
        log.info("connection management: \(action.rawValue) applied \(applied)/\(steps.count)")
    }
}

/// Which properties configuration protection re-applies for one display.
///
/// The list is derived from `ProtectedProperties.available(for:)`, so a display
/// that cannot report a property cannot be asked to protect it — the control is
/// disabled and says why, rather than silently doing nothing.
@MainActor
private struct DisplayProtectionSection: View {
    let display: Display

    private let protection: ConfigProtectionController
    private let available: ProtectedProperties
    @State private var selection: ProtectedProperties

    init(display: Display) {
        self.display = display
        let controller = ConfigProtectionController()
        self.protection = controller
        self.available = ProtectedProperties.available(for: display)
        _selection = State(initialValue: controller.protectedProperties(for: display))
    }

    var body: some View {
        SettingsGroup {
            ForEach(ProtectedPropertyLabels.ordered, id: \.rawValue) { property in
                let isAvailable = available.contains(property)
                Toggle(ProtectedPropertyLabels.label(for: property), isOn: binding(for: property))
                    .disabled(!isAvailable)
                    .help(isAvailable ? "" : String(localized: "This display does not report \(ProtectedPropertyLabels.list(property))."))
            }
        } header: {
            Text("Configuration protection")
        } footer: {
            Text("Re-applies the selected properties when this display reconnects. Properties this display cannot report are unavailable.")
                .fbdLeadingFooter()
        }
    }

    private func binding(for property: ProtectedProperties) -> Binding<Bool> {
        Binding(
            get: { selection.contains(property) },
            set: { on in
                if on { selection.insert(property) } else { selection.remove(property) }
                protection.setProtectedProperties(selection, for: display)
            }
        )
    }
}

/// Five recall slots for this display's current mode.
@MainActor
private struct DisplayFavouritesSection: View {
    let display: Display

    private let resolution = ResolutionController()
    @State private var refresh = 0
    @State private var message: String?

    var body: some View {
        SettingsGroup {
            ForEach(1...ModeFavourites.slotCount, id: \.self) { slot in
                let favourite = ModeFavourites.favourite(slot: slot, for: display.identityKey)
                HStack(spacing: FBDTheme.spacingM) {
                    Text("\(slot).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(favourite.map(summary) ?? String(localized: "empty"))
                        .font(.caption)
                        .foregroundStyle(favourite == nil ? .tertiary : .primary)
                    Spacer(minLength: 8)
                    Button("Save") { save(slot) }
                        .controlSize(.small)
                    Button("Apply") { apply(slot) }
                        .controlSize(.small)
                        .disabled(favourite == nil)
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Resolution favourites")
        } footer: {
            Text("Record the current display mode into a slot and recall it later.")
                .fbdLeadingFooter()
        }
        .id(refresh)
    }

    private func summary(_ favourite: ModeFavourite) -> String {
        var text = "\(favourite.width) × \(favourite.height)"
        if favourite.isHiDPI { text += " HiDPI" }
        if favourite.refreshRate > 0 { text += String(format: " @ %.2f Hz", favourite.refreshRate) }
        return text
    }

    private func save(_ slot: Int) {
        guard let mode = resolution.currentMode(for: display) else {
            message = String(localized: "No current mode to record.")
            return
        }
        _ = ModeFavourites.save(mode, into: slot, for: display.identityKey)
        message = String(localized: "Recorded slot \(slot).")
        refresh += 1
    }

    private func apply(_ slot: Int) {
        let recall = resolution.applyFavourite(slot: slot, for: display.identityKey, to: display)
        message = recall.isUnavailable
            ? "Slot \(slot) no longer has a matching mode on this display."
            : "Applied slot \(slot)."
        refresh += 1
    }
}

// MARK: - Presets

/// Named presets for this display: a whole configuration, saved under a name and
/// applied again later from here, from `fbdcli config preset` or from an App Intent.
///
/// A preset is captured and re-applied through the same path configuration
/// protection uses, so it restores exactly what protection would — and, like it,
/// reports the properties this display cannot report rather than claiming to have
/// set them.
@MainActor
private struct DisplayPresetsSection: View {
    let display: Display

    private let resolution = ResolutionController()
    @State private var presets: [DisplayPreset] = []
    @State private var newName = ""
    @State private var newSymbol: DisplayPresetSymbol = .default
    @State private var message: String?

    var body: some View {
        SettingsGroup {
            if presets.isEmpty {
                Text("No presets saved.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            ForEach(presets) { preset in
                HStack(spacing: FBDTheme.spacingM) {
                    Image(systemName: preset.symbol.symbolName)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preset.name)
                            .font(.caption)
                        Text(ProtectedPropertyLabels.list(preset.properties))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Apply") { apply(preset) }
                        .controlSize(.small)
                    Button("Delete") { delete(preset) }
                        .controlSize(.small)
                }
            }

            HStack(spacing: FBDTheme.spacingS) {
                TextField("New preset name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                Picker("Icon", selection: $newSymbol) {
                    ForEach(DisplayPresetSymbol.all, id: \.self) { symbol in
                        Label(symbol.label, systemImage: symbol.symbolName)
                            .tag(symbol)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 140)
                Button("Save") { save() }
                    .controlSize(.small)
                    .disabled(DisplayPresets.sanitizedName(newName) == nil)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Display presets")
        } footer: {
            Text("Save this display's current configuration under a name and apply it again later. A preset never changes which display is the main one.")
                .fbdLeadingFooter()
        }
        .onAppear { reload() }
    }

    private func reload() {
        presets = DisplayPresets.presets(for: display.identityKey)
    }

    /// Saves the current configuration under the typed name. The symbol is the
    /// picker's, and the property set is the default one — the CLI can choose
    /// otherwise, but a preset that quietly excluded brightness would be worse
    /// than one that reports brightness as skipped.
    private func save() {
        guard let name = DisplayPresets.sanitizedName(newName) else { return }
        let preset = DisplayPreset(
            name: name,
            symbol: newSymbol,
            properties: DisplayPresets.defaultProperties,
            state: DisplayStateSnapshot.capture(
                for: display,
                resolution: resolution,
                controller: DisplayController.shared
            )
        )
        guard DisplayPresets.save(preset, for: display.identityKey) else {
            message = String(localized: "A preset named '\(name)' already exists.")
            return
        }
        message = String(localized: "Saved preset '\(name)'.")
        newName = ""
        reload()
    }

    private func apply(_ preset: DisplayPreset) {
        let outcome = DisplayPresetApplier.apply(
            preset,
            to: display,
            resolution: resolution,
            controller: DisplayController.shared
        )
        if outcome.applied.isEmpty && !outcome.requested.isEmpty {
            message = String(localized: "Nothing in '\(preset.name)' applies to this display.")
        } else if outcome.unavailable.isEmpty {
            message = String(localized: "Applied '\(preset.name)'.")
        } else {
            message = String(localized: "Applied '\(preset.name)' — skipped \(ProtectedPropertyLabels.list(outcome.unavailable)).")
        }
    }

    private func delete(_ preset: DisplayPreset) {
        _ = DisplayPresets.remove(id: preset.id, for: display.identityKey)
        message = nil
        reload()
    }
}

private extension View {
    /// A grouped `Form` lays a footer out trailing-aligned; these explain the section above
    /// them, so they read from the leading edge like the rest of the form.
    func fbdLeadingFooter() -> some View {
        multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
