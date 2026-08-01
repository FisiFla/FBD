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
        }
        .padding(.vertical, 6)
        .onReceive(NotificationCenter.default.publisher(for: .fbdDisplayUpdated)) { note in
            if let id = note.userInfo?["displayID"] as? CGDirectDisplayID, id == display.id {
                refreshTick += 1
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
}
