import CoreGraphics
import FBDCore
import SwiftUI

/// Per-display row: name + badge, current resolution, brightness slider, and
/// DDC/CI controls (contrast, volume, mute, input source) plus a
/// "Resolutions…" disclosure and a capabilities read button.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(display.name)
                    .font(.headline)
                    .lineLimit(1)
                ForEach(badges, id: \.self) { badge in
                    Text(badge)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Spacer(minLength: 8)
                if !resolutionLabel.isEmpty {
                    Text(resolutionLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            BrightnessSliderView(display: display)

            DisclosureGroup("Resolutions…") {
                resolutionsList
            }
            .font(.caption)

            if display.ddcAvailable {
                ddcControls
            }

            if display.isXDRCapable {
                DisclosureGroup {
                    xdrControls
                } label: {
                    Text("XDR / HDR")
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            syncUpscaleTarget()
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

    // MARK: - Derived state

    private var badges: [String] {
        var result: [String] = []
        if display.isBuiltin { result.append("Built-in") }
        if display.ddcAvailable { result.append("DDC") }
        if display.isVirtual { result.append("Virtual") }
        return result
    }

    private var resolutionLabel: String {
        guard let mode = display.currentMode else { return "" }
        var label = mode.label
        if !mode.refreshLabel.isEmpty {
            label += " · \(mode.refreshLabel)"
        }
        return label
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
        .padding(.top, 2)
    }

    // MARK: - DDC/CI controls

    private var ddcControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            sliderRow(
                label: "Contrast",
                value: Binding(get: { contrast }, set: { contrast = $0 }),
                send: { DisplayController.shared.setContrast($0, on: display) }
            )
            sliderRow(
                label: "Volume",
                value: Binding(get: { volume }, set: { volume = $0 }),
                send: { DisplayController.shared.setVolume($0, on: display) }
            )
            HStack(spacing: 8) {
                Toggle("Mute", isOn: Binding(
                    get: { muted },
                    set: { muted = $0; DisplayController.shared.setMuted($0, on: display) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
                TextField("Input source", text: $inputSource)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .help("DDC input source (VCP 0x60), 1–15")
                Button("Apply") {
                    applyInputSource()
                }
                .controlSize(.small)
            }
            Button("Read DDC capabilities") {
                DisplayController.shared.readCapabilities(for: display)
            }
            .controlSize(.small)
        }
    }

    private func sliderRow(label: String, value: Binding<Double>, send: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 56, alignment: .leading)
            Slider(
                value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = $0; send($0) }
                ),
                in: 0...1
            )
        }
    }

    private func applyInputSource() {
        let trimmed = inputSource.trimmingCharacters(in: .whitespaces)
        guard let value = UInt16(trimmed), value > 0 else { return }
        DisplayController.shared.setInputSource(value, on: display)
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
                .controlSize(.small)
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
                        .frame(width: 56, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { upscaleTargetNits },
                            set: { newValue in
                                upscaleTargetNits = newValue
                                scheduleUpscaleTargetWrite(Int(newValue))
                            }
                        ),
                        in: range
                    )
                    Text("\(Int(upscaleTargetNits)) nits")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
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
