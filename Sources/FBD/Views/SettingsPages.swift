import FBDCore
import os
import ServiceManagement
import SwiftUI

// The Settings pages themselves, one view per sidebar entry. The shell that
// navigates between them lives in `SettingsView.swift`.
//
// Layout convention: a `Form` with `.grouped` style and one `Section` per
// group of related controls, each section carrying a short caption explaining
// what the group does — the same shape BetterDisplay's per-display pages use,
// written in FBD's own words.

// MARK: - Shared row helpers
//
// The label/value/caption row shapes live in the design system
// (`FDBSettingsRow.swift`), so every settings page keeps one shape.

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

                    connectionManagementSection(displays)
                        .padding(.horizontal, 12)

                    ForEach(shown) { display in
                        VStack(spacing: FBDTheme.spacingM) {
                            PerDisplayCardView(display: display)
                            DisplayProtectionSection(display: display)
                            DisplayFavouritesSection(display: display)
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
/// The HUD's look and placement, plus the Dock visibility rules.
///
/// Its own view because the whole style is **one stored value**: the controls bind
/// to a local copy and save it on change, rather than each writing its own key —
/// which would split one setting across several and allow a partial write.
private struct OSDStyleSection: View {
    @State private var style = OSDStyle.load()

    var body: some View {
        Group {
            SettingsRow(title: "HUD position") {
                Picker("", selection: $style.position) {
                    ForEach(OSDStyle.Position.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            SettingsRow(title: "HUD bar") {
                Picker("", selection: $style.barStyle) {
                    ForEach(OSDStyle.BarStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            SettingsRow(title: "HUD background") {
                Picker("", selection: $style.background) {
                    ForEach(OSDStyle.Background.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            Toggle("HUD shadow", isOn: $style.showsShadow)

            SettingsSliderRow(
                title: "HUD corner radius",
                value: style.cornerRadius,
                range: OSDStyle.cornerRadiusRange,
                format: { "\(Int($0))" },
                caption: nil,
                onChange: { style.cornerRadius = $0 }
            )

            Toggle("Show FBD in the Dock", isOn: bool(Settings.showDockIcon) { Settings.showDockIcon = $0 })
            Toggle("Brief Dock icon at launch", isOn: bool(Settings.briefDockIconAtStartup) { Settings.briefDockIconAtStartup = $0 })
            Text("A menu-bar app normally has no Dock icon. These make it findable there — permanently, or only just after it opens.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: style) { newValue in OSDStyle.save(newValue) }
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
}

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

// MARK: - Groups

/// Display groups, their activation policy and their synchronisation filters.
@MainActor
struct GroupsSettingsPage: View {
    @State private var controller = DisplayGroupsController()
    @State private var groups: [DisplayGroup] = []
    @State private var newGroupName = ""

    var body: some View {
        Form {
            Section {
                Text("Display groups let one operation affect several displays: brightness synchronisation, UI scale matching and layout management.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: FBDTheme.spacingM) {
                    TextField("New group name", text: $newGroupName)
                    Button("Create") {
                        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        controller.createGroup(name: name)
                        newGroupName = ""
                        reload()
                    }
                    .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if groups.isEmpty {
                    Text("No groups yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Display groups", systemImage: "rectangle.3.group")
            }

            ForEach(groups) { group in
                Section {
                    Toggle("Synchronise this group", isOn: enabledBinding(group))
                    Text("When off, group operations are skipped entirely for this group.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Activate when", selection: policyBinding(group)) {
                        ForEach(GroupActivationPolicy.allCases, id: \.self) { policy in
                            Text(label(for: policy)).tag(policy)
                        }
                    }
                    Text(policyCaption(controller.activationPolicy(forGroup: group.id)))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: FBDTheme.spacingM) {
                        Text("\(group.displayIDs.count) display\(group.displayIDs.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Sync now") { syncNow(group) }
                            .controlSize(.small)
                            .disabled(group.displayIDs.count < 2 || !controller.isEnabled(groupID: group.id))
                            .help("Propagate the first connected member's current brightness to the rest of the group.")
                        Button("Mirror") { _ = controller.mirror(inGroup: group.id) }
                            .controlSize(.small)
                            .disabled(group.displayIDs.count < 2)
                        Button("Unmirror") { _ = controller.unmirror(inGroup: group.id) }
                            .controlSize(.small)
                        Button("Delete", role: .destructive) {
                            controller.deleteGroup(id: group.id)
                            reload()
                        }
                        .controlSize(.small)
                    }
                } header: {
                    Label(group.name, systemImage: "rectangle.3.group")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    private func reload() { groups = controller.groups }

    private func enabledBinding(_ group: DisplayGroup) -> Binding<Bool> {
        Binding(
            get: { controller.isEnabled(groupID: group.id) },
            set: { controller.setEnabled($0, forGroup: group.id) }
        )
    }

    private func policyBinding(_ group: DisplayGroup) -> Binding<GroupActivationPolicy> {
        Binding(
            get: { controller.activationPolicy(forGroup: group.id) },
            set: { controller.setActivationPolicy($0, forGroup: group.id) }
        )
    }

    /// Propagate the group's reference display's current brightness to the rest
    /// of the group, through the same tested planner an explicit value uses.
    ///
    /// This was the missing half of group sync: the enabled flag and the
    /// activation policy were configurable here, but nothing in the app could
    /// actually trigger a sync — only `fbdcli config group-sync` could.
    private func syncNow(_ group: DisplayGroup) {
        let displays = DisplayController.shared.displays
        // Read every member's brightness once, up front, so the closure handed to
        // the controller is a plain lookup: it touches no DDC bus and no actor.
        var brightnessByID: [CGDirectDisplayID: Double] = [:]
        for display in displays {
            if let value = display.brightness ?? DisplayController.shared.getBrightness(for: display) {
                brightnessByID[display.id] = value
            }
        }
        guard let reading = controller.syncValue(
            inGroup: group.id,
            connectedIDs: Set(displays.map { $0.id }),
            currentBrightness: { brightnessByID[$0] }
        ) else {
            return
        }
        _ = controller.applyGroupSync(
            reading.value,
            inGroup: group.id,
            controller: .shared,
            referenceDisplayID: reading.sourceDisplayID
        )
    }

    private func label(for policy: GroupActivationPolicy) -> String {
        switch policy {
        case .always: return "Always"
        case .allMembersPresent: return "All members present"
        case .anyMembersPresent: return "Any member present"
        case .anyTwoMembersPresent: return "Any two members present"
        case .anySyncSourceWithTargetMembersPresent: return "A sync source and target present"
        }
    }

    private func policyCaption(_ policy: GroupActivationPolicy) -> String {
        switch policy {
        case .always: return "The group is always active."
        case .allMembersPresent: return "The group is active only while every member is connected."
        case .anyMembersPresent: return "The group is active while at least one member is connected."
        case .anyTwoMembersPresent: return "The group is active while at least two members are connected."
        case .anySyncSourceWithTargetMembersPresent: return "The group is active while both a sync source and a sync target are connected."
        }
    }
}

// MARK: - Application

/// App-level settings: launch, updates, the brightness model, integrations and
/// automation.
@MainActor
struct ApplicationSettingsPage: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hotkeysUnavailable = false
    @State private var nightShift = NightShiftController()
    @State private var trueTone = TrueToneController()
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "App")

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                Toggle("Show Rosetta warning", isOn: bool(Settings.showRosettaWarning) { Settings.showRosettaWarning = $0 })
                Toggle("Enable connect/disconnect for displays", isOn: bool(Settings.enableDisconnectOption) { Settings.enableDisconnectOption = $0 })
                if hotkeysUnavailable {
                    Label("Media keys unavailable — allow Accessibility for FBD in System Settings", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("General", systemImage: "gearshape")
            }

            brightnessModelSection
            brightnessSection
            lockDimSection

            Section {
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

            Section {
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
                Toggle("Custom OSD", isOn: bool(Settings.customOSDEnabled) { Settings.customOSDEnabled = $0 })
                Text("Shows a brightness HUD when the display brightness changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                OSDStyleSection()
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
            } header: {
                Label("Integrations", systemImage: "network")
            }

            Section {
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

            Section {
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
        .formStyle(.grouped)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
        .onReceive(NotificationCenter.default.publisher(for: .fbdHotkeysUnavailable)) { _ in
            hotkeysUnavailable = true
        }
    }

    // MARK: Brightness model

    /// The knobs that shape the combined-brightness curve. Global rather than
    /// per-display, because they describe the model, not one monitor.
    private var brightnessModelSection: some View {
        Section {
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
        Section {
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
        Section {
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

    /// True Tone lives on a MainActor-isolated controller, so it needs its own
    /// binding rather than the `bool`/`int` helpers above.
    private var trueToneBinding: Binding<Bool> {
        Binding(
            get: { trueTone.isEnabled() ?? false },
            set: { _ = trueTone.setEnabled($0) }
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

// MARK: - Menu

/// Options that affect the menu-bar panel and the display menus.
@MainActor
struct MenuSettingsPage: View {
    var body: some View {
        Form {
            Section {
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

            Section {
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

            Section {
                Text("The panel shows one card per display, with brightness, filters, resolutions and XDR/HDR controls, and a footer for Virtual Screens, Groups, PiP, updates and quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Right-click the status item for Show FBD, Settings…, Check for Updates… and Quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Panel contents", systemImage: "menubar.rectangle")
            }

            Section {
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
        .formStyle(.grouped)
    }
}

// MARK: - Keyboard

/// Media-key handling and which display the keys act on.
@MainActor
struct KeyboardSettingsPage: View {
    @State private var hotkeysUnavailable = false

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
                if hotkeysUnavailable {
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
        .onReceive(NotificationCenter.default.publisher(for: .fbdHotkeysUnavailable)) { _ in
            hotkeysUnavailable = true
        }
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

// MARK: - About

@MainActor
struct AboutSettingsPage: View {
    var body: some View {
        Form {
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
    }

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}
