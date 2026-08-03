import AppKit
import CoreGraphics
import FBDCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Per-display card: icon tile + name + capability tags, a nits-aware
/// brightness slider, and DDC/CI controls, XDR, EDID, resolutions and
/// color-profile sections — each a labeled disclosure row.
@MainActor
struct DisplayRowView: View {
    @ObservedObject var display: Display

    // Send-only DDC controls have no readable state on Display yet — keep the
    // last sent value locally so the controls stay interactive.
    @State private var contrast: Double = 0.5
    @State private var volume: Double = 0.5
    @State private var muted = false
    @State private var inputSource = ""
    /// Bumped when .fbdDisplayUpdated fires for this display to re-render.
    @State private var refreshTick = 0
    /// XDR upscale target while the slider is being dragged (written through
    /// locally so the thumb tracks the finger; persisted via the controller,
    /// trailing-debounced so we don't hammer the WindowServer).
    @State private var upscaleTargetNits: Double = 0
    @State private var upscaleDebounceWorkItem: DispatchWorkItem?
    /// Confirmation for the soft-disconnect action.
    @State private var confirmingDisable = false
    /// PiP / video-filter window controller (shared — one window process-wide).
    @State private var pipController = PipStreamController.shared

    // MARK: EDID & color profile (Tier 4)

    /// Held in @State so its per-instance factory-EDID capture survives across
    /// body evaluations (same pattern as DisplayListView's controllers).
    @State private var edidController = EDIDController()
    @State private var colorProfileController = ColorProfileController()
    /// Exported EDID + parsed summary shown inside the EDID disclosure.
    @State private var edidData: Data?
    @State private var edidSummary: EDIDParser.ParsedEDID?
    /// Last EDID action result ("…applied", "…failed") for inline feedback.
    @State private var edidStatus: String?
    @State private var edidStatusIsError = false
    /// Color profiles, loaded lazily once per row appearance.
    @State private var colorProfiles: [ColorProfile] = []
    @State private var colorProfilesLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            BrightnessSliderView(display: display)
            disclosureSection(icon: "slider.horizontal.3", title: "Filters") {
                filterControls
            }
            if display.ddcAvailable {
                ddcPanel
            }
            if !display.modes.isEmpty {
                disclosureSection(icon: "list.bullet.rectangle", title: "Resolutions") {
                    resolutionsList
                }
            }
            if display.isXDRCapable {
                disclosureSection(icon: "sun.max.trianglebadge.exclamationmark", title: "XDR / HDR") {
                    xdrControls
                }
            }
            if !display.isBuiltin {
                disclosureSection(icon: "rectangle.dashed", title: "EDID") {
                    edidControls
                }
            }
            colorProfileControls
            disableRow
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: FBDTheme.radiusCard, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: FBDTheme.radiusCard, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onAppear {
            syncUpscaleTarget()
            loadColorProfilesIfNeeded()
        }
        .onChange(of: display.isXDRUpscaled) { upscaled in
            if upscaled { syncUpscaleTarget() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fbdDisplayUpdated)) { note in
            if let id = note.userInfo?["displayID"] as? CGDirectDisplayID, id == display.id {
                refreshTick += 1
                syncUpscaleTarget()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            // Display-kind tile.
            RoundedRectangle(cornerRadius: FBDTheme.radiusTile, style: .continuous)
                .fill(kind.tint.opacity(0.16))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: kind.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(kind.tint)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(display.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    capabilityTags
                }
                if !resolutionLabel.isEmpty {
                    Text(resolutionLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)

            // Options menu (ellipsis) — the single entry point for the
            // per-display submenus and quick toggles.
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

            // Soft-disconnect power button (gated by the connect/disconnect setting).
            if Settings.enableDisconnectOption {
                Button {
                    confirmingDisable = true
                } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(display.isOnline ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            .help(display.isOnline ? "Disable display" : "Display offline")
            .accessibilityLabel(display.isOnline ? "Disable display" : "Re-enable display")
            .accessibilityHint("Display will go dark until re-enabled")
            .confirmationDialog(
                "Disable display?",
                isPresented: $confirmingDisable,
                titleVisibility: .visible
            ) {
                Button("Disable", role: .destructive) {
                    _ = DisconnectController().setEnabled(false, displayID: display.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Display will go dark until re-enabled.")
            }
            }
        }
    }

    private var kind: DisplayKind { DisplayKind(display: display) }

    @ViewBuilder
    private var capabilityTags: some View {
        HStack(spacing: 4) {
            FBDTag(text: kind.label, tint: kind.tint)
            if display.ddcAvailable {
                FBDTag(text: "DDC", tint: .teal)
            }
            if display.isXDRCapable {
                FBDTag(text: "XDR", tint: .orange)
            } else if display.isHDRModeCapable {
                FBDTag(text: "HDR", tint: .orange)
            }
        }
        .layoutPriority(1)
    }

    // MARK: - Options menu

    /// The full per-display options menu (BetterDisplay-style): one ellipsis
    /// button in the card header; the old quick-toggles row (HiDPI / Auto
    /// Brightness / Notch) was folded in here and the dead Notch toggle
    /// removed.
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

        // Stream / Picture in Picture
        Button("Stream Display") {
            startVideoFilterWindow()
        }
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

    @State private var filterParams = ScreenFilterParams.neutral

    private var filterActiveBinding: Binding<Bool> {
        Binding(
            get: { !filterParams.isNeutral },
            set: { active in
                if active {
                    _ = DisplayController.shared.setScreenFilter(filterParams, on: display)
                } else {
                    resetScreenFilter()
                }
            }
        )
    }

    private var filterContrast: Binding<Double> {
        Binding(
            get: { filterParams.contrast },
            set: { filterParams.contrast = $0; applyScreenFilter() }
        )
    }

    private var filterSaturation: Binding<Double> {
        Binding(
            get: { filterParams.saturation },
            set: { filterParams.saturation = $0; applyScreenFilter() }
        )
    }

    private var filterGamma: Binding<Double> {
        Binding(
            get: { filterParams.gamma },
            set: { filterParams.gamma = $0; applyScreenFilter() }
        )
    }

    private var filterTemperature: Binding<Double> {
        Binding(
            get: { filterParams.temperature },
            set: { filterParams.temperature = $0; applyScreenFilter() }
        )
    }

    private var filterInvert: Binding<Bool> {
        Binding(
            get: { filterParams.invert },
            set: { filterParams.invert = $0; applyScreenFilter() }
        )
    }

    private func applyScreenFilter() {
        if filterParams.isNeutral {
            DisplayController.shared.stopScreenFilter(on: display)
        } else {
            _ = DisplayController.shared.setScreenFilter(filterParams, on: display)
        }
    }

    private func resetScreenFilter() {
        filterParams = .neutral
        DisplayController.shared.stopScreenFilter(on: display)
    }

    /// Full-screen software filter controls (contrast / saturation / gamma /
    /// color temperature / invert). Moved out of the options menu — sliders
    /// inside menus are fragile; a disclosure row matches the card's other
    /// sections.
    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Apply to Display", isOn: filterActiveBinding)
            Slider(value: filterContrast, in: 0.5...2, step: 0.05) {
                Text("Contrast")
            } minimumValueLabel: {
                Text("0.5")
            } maximumValueLabel: {
                Text("2")
            }
            .font(.caption)
            Slider(value: filterSaturation, in: 0...2, step: 0.05) {
                Text("Saturation")
            } minimumValueLabel: {
                Text("0")
            } maximumValueLabel: {
                Text("2")
            }
            .font(.caption)
            Slider(value: filterGamma, in: 0.4...2.5, step: 0.05) {
                Text("Gamma")
            } minimumValueLabel: {
                Text("0.4")
            } maximumValueLabel: {
                Text("2.5")
            }
            .font(.caption)
            Slider(value: filterTemperature, in: 0.5...1.5, step: 0.05) {
                Text("Color Temperature")
            } minimumValueLabel: {
                Text("Warm")
            } maximumValueLabel: {
                Text("Cool")
            }
            .font(.caption)
            Toggle("Invert Colors", isOn: filterInvert)
            Button("Reset") {
                resetScreenFilter()
            }
            .controlSize(.small)
        }
    }

    // MARK: - Disclosure sections

    /// Consistent disclosure-row style: small icon + title + chevron.
    private func disclosureSection(
        icon: String,
        title: String,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        DisclosureGroup {
            content()
                .padding(.top, 4)
        } label: {
            Label(title, systemImage: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Resolutions

    private var resolutionLabel: String {
        guard let mode = display.currentMode else { return "" }
        var label = mode.label
        if !mode.refreshLabel.isEmpty {
            label += " · \(mode.refreshLabel)"
        }
        return label
    }

    private var resolutionsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if display.modes.isEmpty {
                Text("No modes available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(display.modes, id: \.self) { mode in
                    Button {
                        DisplayController.shared.applyMode(mode, to: display)
                    } label: {
                        HStack(spacing: 6) {
                            Text(mode.label)
                            if !mode.refreshLabel.isEmpty {
                                Text(mode.refreshLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if mode.isHiDPI {
                                Text("HiDPI")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if mode == display.currentMode {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - DDC/CI controls

    private var ddcPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("DDC / CI", systemImage: "cable.connector")
                .font(.caption.weight(.medium))
                .foregroundStyle(.teal)

            sliderRow(label: "Contrast", value: Binding(
                get: { contrast },
                set: { contrast = $0 }
            )) { DisplayController.shared.setContrast($0, on: display) }

            sliderRow(label: "Volume", value: Binding(
                get: { volume },
                set: { volume = $0 }
            )) { DisplayController.shared.setVolume($0, on: display) }

            HStack(spacing: 8) {
                Toggle("Mute", isOn: Binding(
                    get: { muted },
                    set: { muted = $0; DisplayController.shared.setMuted($0, on: display) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Mute \(display.name)")
                Spacer()
                TextField("Input", text: $inputSource)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 50, idealWidth: 70, maxWidth: 90)
                    .help("DDC input source (VCP 0x60), 1–15")
                    .accessibilityLabel("Input source for \(display.name)")
                Button("Apply") {
                    applyInputSource()
                }
                .controlSize(.small)
            }

            Button {
                DisplayController.shared.readCapabilities(for: display)
            } label: {
                Label("Read capabilities", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: FBDTheme.radiusInset, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))
        )
    }

    private func sliderRow(
        label: String,
        value: Binding<Double>,
        send: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            FDBSlider(
                value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = $0; send($0) }
                ),
                in: 0...1,
                accessibilityLabel: "\(label) for \(display.name)",
                valueText: { "\(Int(($0 * 100).rounded()))%" }
            )
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private func applyInputSource() {
        let trimmed = inputSource.trimmingCharacters(in: .whitespaces)
        guard let value = UInt16(trimmed), value > 0 else { return }
        DisplayController.shared.setInputSource(value, on: display)
    }

    // MARK: - Disable / re-enable

    private var disableRow: some View {
        Group {
            if !display.isOnline {
                Button {
                    _ = DisconnectController().setEnabled(true, displayID: display.id)
                } label: {
                    Label("Re-enable display", systemImage: "power")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.blue)
                .controlSize(.small)
            }
        }
    }

    // MARK: - EDID (Tier 4)

    private var edidControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Button("Export EDID…") { exportEDID() }
                    Button("Apply override…") { applyOverrideFromFile() }
                    Button("Restore factory") { restoreFactoryEDID() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Button("Export EDID…") { exportEDID() }
                        Button("Apply override…") { applyOverrideFromFile() }
                    }
                    Button("Restore factory") { restoreFactoryEDID() }
                }
            }
            .controlSize(.small)

            if let edidSummary {
                summaryRow("Manufacturer", edidSummary.manufacturer)
                summaryRow("Product code", "\(edidSummary.productCode) (0x\(String(format: "%04X", edidSummary.productCode)))")
                summaryRow("Serial", "\(edidSummary.serialNumber)")
                summaryRow("Year", edidSummary.weekOfManufacture == 0
                    ? "\(edidSummary.yearOfManufacture)"
                    : "Week \(edidSummary.weekOfManufacture), \(edidSummary.yearOfManufacture)")
                summaryRow("Name", edidSummary.monitorName ?? "—")
                if let timing = edidSummary.preferredTiming {
                    summaryRow("Preferred timing", "\(timing.width)×\(timing.height)")
                } else {
                    summaryRow("Preferred timing", "—")
                }
                summaryRow("Checksum", edidSummary.isChecksumValid ? "valid" : "INVALID")
            }

            if let edidData {
                Text("Hex dump (\(edidData.count) bytes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView([.vertical, .horizontal]) {
                    Text(hexDump(edidData))
                        .font(.system(.caption2, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 110)
                Button("Save to file…") { saveEDIDToFile() }
                    .controlSize(.small)
            }

            if let edidStatus {
                Text(edidStatus)
                    .font(.caption)
                    .foregroundStyle(edidStatusIsError ? Color.red : Color.secondary)
            }

            if let saved = edidController.savedOverride(for: display) {
                Text("Override saved (\(saved.count) bytes) — auto-applies on connect")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No saved override")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, idealWidth: 96, alignment: .leading)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private func exportEDID() {
        guard let data = edidController.exportEDID(for: display) else {
            edidStatus = "Could not read EDID for this display"
            edidStatusIsError = true
            return
        }
        edidData = data
        edidSummary = EDIDParser.parse(data)
        edidStatus = "Exported \(data.count)-byte EDID"
        edidStatusIsError = false
    }

    private func saveEDIDToFile() {
        guard let edidData else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "Save EDID"
        panel.nameFieldStringValue = "FBD-EDID-\(display.identityKey).bin"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try edidData.write(to: url)
                edidStatus = "Saved to \(url.lastPathComponent)"
                edidStatusIsError = false
            } catch {
                edidStatus = "Save failed: \(error.localizedDescription)"
                edidStatusIsError = true
            }
        }
    }

    private func applyOverrideFromFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose EDID file"
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url) else {
                edidStatus = "Could not read \(url.lastPathComponent)"
                edidStatusIsError = true
                return
            }
            if edidController.applyOverride(data, for: display) {
                edidData = data
                edidSummary = EDIDParser.parse(data)
                edidStatus = "Override applied (\(data.count) bytes)"
                edidStatusIsError = false
            } else {
                edidStatus = edidController.isAvailable
                    ? "Failed to apply override"
                    : "Failed — EDID override requires Apple Silicon"
                edidStatusIsError = true
            }
            refreshTick += 1
        }
    }

    private func restoreFactoryEDID() {
        // Pass the current export (or fetch one) as the caller-provided
        // original; the controller prefers its own factory capture.
        let original = edidData ?? edidController.exportEDID(for: display)
        if edidController.restoreFactory(originalEDID: original, for: display) {
            edidStatus = "Factory EDID restored"
            edidStatusIsError = false
        } else {
            edidStatus = edidController.isAvailable
                ? "Failed to restore factory EDID"
                : "Failed — EDID override requires Apple Silicon"
            edidStatusIsError = true
        }
        refreshTick += 1
    }

    /// 16 bytes per line, offset + hex + ASCII gutter.
    private func hexDump(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var lines: [String] = []
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = chunk.map { byte -> Character in
                (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
            }
            lines.append(String(format: "%04X  %-47@  %@", offset, hex, String(ascii)))
            offset += 16
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Color profile (Tier 4)

    /// Always visible once profiles exist for this display. Selection is the
    /// display's current default profile URL; picking one applies it.
    private var colorProfileControls: some View {
        Group {
            if !colorProfiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Color Profile", selection: colorProfileBinding) {
                        ForEach(colorProfiles) { profile in
                            Text(profile.name).tag(profile.url as URL?)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    Button("Restore default") {
                        if colorProfileController.restoreDefault(for: display) {
                            refreshTick += 1
                        }
                    }
                    .controlSize(.small)
                    .disabled(colorProfileController.defaultProfile(for: display) == nil)
                }
            }
        }
    }

    /// get = current default; set = apply (matches the Binding get/set pattern
    /// used by the mute/XDR toggles).
    private var colorProfileBinding: Binding<URL?> {
        Binding(
            get: { colorProfileController.defaultProfile(for: display) },
            set: { url in
                guard let url else { return }
                if colorProfileController.applyProfile(url, for: display) {
                    refreshTick += 1
                }
            }
        )
    }

    /// Load profiles once per row appearance; empty result keeps the picker hidden.
    private func loadColorProfilesIfNeeded() {
        guard !colorProfilesLoaded else { return }
        colorProfilesLoaded = true
        colorProfiles = colorProfileController.profiles(for: display)
    }

    // MARK: - XDR / HDR controls

    private var xdrControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("XDR upscaling", isOn: Binding(
                get: { display.isXDRUpscaled },
                set: { on in
                    if on {
                        DisplayController.shared.setXDRUpscaleTarget(Int(Settings.xdrUpscaleTargetNits), on: display)
                    } else {
                        DisplayController.shared.disableXDRUpscaling(on: display)
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            if display.isXDRUpscaled {
                upscaleSlider
                Text("Upscaled to \(display.xdrUpscaleTargetNits ?? Settings.xdrUpscaleTargetNits) nits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !validPresets.isEmpty {
                Picker("Preset", selection: presetBinding) {
                    ForEach(validPresets) { preset in
                        Text(preset.name).tag(preset.index)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }

            if display.isHDRModeCapable {
                Toggle("HDR mode", isOn: Binding(
                    get: { display.isHDRModeEnabled },
                    set: { DisplayController.shared.setHDRMode($0, on: display) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    private var upscaleSlider: some View {
        Group {
            if let range = upscaleRange {
                HStack(spacing: 8) {
                    Text("Target")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    FDBSlider(
                        value: Binding(
                            get: { upscaleTargetNits },
                            set: { newValue in
                                upscaleTargetNits = newValue
                                scheduleUpscaleTargetWrite(Int(newValue))
                            }
                        ),
                        in: range,
                        accessibilityLabel: "XDR upscale target for \(display.name)",
                        valueText: { "\(Int($0.rounded())) nits" }
                    )
                    Text("\(Int(upscaleTargetNits)) nits")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            }
        }
    }

    private var validPresets: [XDRPreset] {
        display.presets.filter { $0.isValid }
    }

    /// Slider bounds from the first valid preset: min slider brightness…HDR max.
    private var upscaleRange: ClosedRange<Double>? {
        guard let preset = validPresets.first,
              preset.maxHDRLuminance > preset.minSliderBrightness else { return nil }
        return Double(preset.minSliderBrightness)...Double(preset.maxHDRLuminance)
    }

    private var presetBinding: Binding<Int> {
        Binding(
            get: { display.activePresetIndex ?? SkyLightAPI.factoryDefaultPresetIndex(for: display.id) },
            set: { DisplayController.shared.selectPreset($0, on: display) }
        )
    }

    /// Keep the slider's local value in sync with the display's effective
    /// target, clamped to the slider range.
    private func syncUpscaleTarget() {
        guard display.isXDRUpscaled, let range = upscaleRange else { return }
        let raw = Double(display.xdrUpscaleTargetNits ?? Settings.xdrUpscaleTargetNits)
        upscaleTargetNits = min(max(raw, range.lowerBound), range.upperBound)
    }

    /// Trailing-debounced write of the upscale target: the slider drags at
    /// ~60 Hz and every change re-applies, but SLS preset writes are coalesced
    /// to one write 150 ms after the drag settles.
    private func scheduleUpscaleTargetWrite(_ nits: Int) {
        upscaleDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            Task { @MainActor in
                DisplayController.shared.setXDRUpscaleTarget(nits, on: display)
            }
        }
        upscaleDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: workItem)
    }
}
