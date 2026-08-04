import AppKit
import FBDCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The per-display disclosure sections: Resolutions, XDR / HDR, EDID and the
/// color-profile picker. Each owns its subsystem's state and helpers:
/// - XDR upscale target (slider-local value + trailing debounce),
/// - EDID export/override/restore (controller + exported data + status),
/// - color profiles (controller + lazily loaded list).
@MainActor
struct DisplaySectionsView: View {
    @ObservedObject var display: Display
    /// Bumped after actions that other views read back (EDID / color-profile
    /// changes) so the whole row re-renders, e.g. the options menu's
    /// "Color Mode" checkmarks.
    @Binding var refreshTick: Int
    /// Bumped by DisplayRowView's `.fbdDisplayUpdated` handler; any change
    /// here re-syncs the XDR upscale slider with the display's effective
    /// target.
    let xdrSyncRequest: Int

    // MARK: XDR upscale target (slider-local, trailing-debounced)

    /// XDR upscale target while the slider is being dragged (written through
    /// locally so the thumb tracks the finger; persisted via the controller,
    /// trailing-debounced so we don't hammer the WindowServer).
    @State private var upscaleTargetNits: Double = 0
    @State private var upscaleDebounceWorkItem: DispatchWorkItem?

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
        Group {
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
        }
        .onAppear {
            syncUpscaleTarget()
            loadColorProfilesIfNeeded()
        }
        .onChange(of: display.isXDRUpscaled) { upscaled in
            if upscaled { syncUpscaleTarget() }
        }
        .onChange(of: xdrSyncRequest) { _ in
            syncUpscaleTarget()
        }
    }

    // MARK: - Resolutions

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
