import FBDCore
import SwiftUI

/// DDC/CI panel: contrast / volume / mute / input source + a capabilities
/// read. Owns the last-sent DDC values (send-only controls have no readable
/// state on Display yet — the local values keep the controls interactive)
/// and re-reads the monitor's real state when the row's refresh handler
/// fires.
@MainActor
struct DDCPanelView: View {
    @ObservedObject var display: Display
    /// Bumped by DisplayRowView's `.fbdDisplayUpdated` handler; any change
    /// here triggers a DDC read-back.
    let refreshRequest: Int

    // Send-only DDC controls have no readable state on Display yet — keep the
    // last sent value locally so the controls stay interactive.
    @State private var contrast: Double = 0.5
    @State private var volume: Double = 0.5
    @State private var muted = false
    @State private var inputSource = ""

    var body: some View {
        ddcPanel
            .onAppear { refreshDDCState() }
            .onChange(of: refreshRequest) { _ in
                refreshDDCState()
            }
    }

    /// Pull the monitor's real contrast / volume / mute state into the UI.
    /// Falls back to the last sent value when the monitor doesn't answer
    /// (some DDC monitors ignore reads).
    private func refreshDDCState() {
        guard display.ddcAvailable else { return }
        if let value = DisplayController.shared.readContrast(for: display) {
            contrast = value
        }
        if let value = DisplayController.shared.readVolume(for: display) {
            volume = value
        }
        if let value = DisplayController.shared.readMuted(for: display) {
            muted = value
        }
    }

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
}
