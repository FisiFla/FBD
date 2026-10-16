import FBDCore
import os
import SwiftUI

// MARK: - Displays

/// The long per-display page: the arrangement grid, the connection-management
/// actions, and one card per display carrying that display's own settings.
@MainActor
struct DisplaySettingsPage: View {
    let targetDisplayID: CGDirectDisplayID?

    @State private var layoutProtection = LayoutProtectionController()
    @State private var hasSavedArrangement = false
    @State private var disconnect = DisconnectController()
    @State private var lastConnectionResult: String?

    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "Settings")

    var body: some View {
        let displays = DisplayController.shared.displays
        let shown = Settings.showOfflineDisplays ? displays : displays.filter(\.isOnline)

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: FBDTheme.spacingM) {
                    if shown.isEmpty {
                        Text("No displays")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 24)
                    }

                    ArrangementGridView()
                        .padding(.horizontal, 12)

                    edgeCrossingSection
                        .padding(.horizontal, 12)

                    connectionManagementSection(displays)
                        .padding(.horizontal, 12)

                    ForEach(shown) { display in
                        VStack(spacing: FBDTheme.spacingM) {
                            PerDisplayCardView(display: display)
                            DisplayProtectionSection(display: display)
                            DisplayFavouritesSection(display: display)
                            DisplayPresetsSection(display: display)
                        }
                        .padding(.horizontal, 12)
                        // Scroll target for a caller that asked Settings to
                        // reveal this display.
                        .id(display.id)
                    }
                }
                .padding(.vertical, 8)
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
        VStack(alignment: .leading, spacing: FBDTheme.spacingS) {
            Text("Connection management")
                .font(.callout.weight(.medium))
            Text("Disconnecting a display turns it off until it is re-enabled. The built-in display is never disconnected on Macs where it may not come back without a reboot.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: FBDTheme.spacingM) {
                Button("Connect all") { run(.connectAll, displays) }
                    .controlSize(.small)
                Button("Disconnect all but main") { run(.disconnectAllButMain, displays) }
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
        }
    }

    /// Pointer crossing between displays whose edges do not line up (Crisp item 9).
    ///
    /// A plain toggle over a stored preference: the controller's own timer picks
    /// the change up, so there is nothing to start or stop here.
    private var edgeCrossingSection: some View {
        VStack(alignment: .leading, spacing: FBDTheme.spacingS) {
            Toggle(
                "Cross misaligned display edges",
                isOn: bool(Settings.edgeCrossingEnabled) { Settings.edgeCrossingEnabled = $0 }
            )
            Text("Lets the pointer move between displays whose edges do not line up, instead of stopping at the gap.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            lastConnectionResult = "No main display — nothing to do."
            return
        }
        let applied = disconnect.apply(steps)
        lastConnectionResult = "\(applied) of \(steps.count) display(s) changed."
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
        VStack(alignment: .leading, spacing: FBDTheme.spacingS) {
            Text("Configuration protection")
                .font(.callout.weight(.medium))
            Text("Re-applies the selected properties when this display reconnects. Properties this display cannot report are unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(ProtectedProperties.ordered, id: \.name) { entry in
                let isAvailable = available.contains(entry.property)
                Toggle(entry.name, isOn: binding(for: entry.property))
                    .disabled(!isAvailable)
                    .help(isAvailable ? "" : "This display does not report \(entry.name).")
            }
        }
        .padding(FBDTheme.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: FBDTheme.radiusCard, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
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
        VStack(alignment: .leading, spacing: FBDTheme.spacingS) {
            Text("Resolution favourites")
                .font(.callout.weight(.medium))
            Text("Record the current display mode into a slot and recall it later.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(1...ModeFavourites.slotCount, id: \.self) { slot in
                let favourite = ModeFavourites.favourite(slot: slot, for: display.identityKey)
                HStack(spacing: FBDTheme.spacingM) {
                    Text("\(slot).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(favourite.map(summary) ?? "empty")
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
        }
        .padding(FBDTheme.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: FBDTheme.radiusCard, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
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
            message = "No current mode to record."
            return
        }
        _ = ModeFavourites.save(mode, into: slot, for: display.identityKey)
        message = "Recorded slot \(slot)."
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
        VStack(alignment: .leading, spacing: FBDTheme.spacingS) {
            Text("Display presets")
                .font(.callout.weight(.medium))
            Text("Save this display's current configuration under a name and apply it again later. A preset never changes which display is the main one.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
                        Text(preset.properties.names.joined(separator: ", "))
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
        }
        .padding(FBDTheme.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: FBDTheme.radiusCard, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
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
            message = "A preset named '\(name)' already exists."
            return
        }
        message = "Saved preset '\(name)'."
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
            message = "Nothing in '\(preset.name)' applies to this display."
        } else if outcome.unavailable.isEmpty {
            message = "Applied '\(preset.name)'."
        } else {
            message = "Applied '\(preset.name)' — skipped \(outcome.unavailable.names.joined(separator: ", "))."
        }
    }

    private func delete(_ preset: DisplayPreset) {
        _ = DisplayPresets.remove(id: preset.id, for: display.identityKey)
        message = nil
        reload()
    }
}
