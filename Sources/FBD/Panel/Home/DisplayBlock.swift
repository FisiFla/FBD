import CoreGraphics
import FBDCore
import SwiftUI

/// One display on the home page: identity header, brightness and (when the
/// monitor answers DDC) volume.
struct DisplayBlock: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var display: Display

    @State private var isHovering = false
    @State private var confirmingDisable = false
    @State private var volume: Double?
    @State private var pendingVolumeWrite: DispatchWorkItem?

    /// "2560 × 1440 · 60 Hz"; the refresh part is dropped when unknown.
    static func subtitle(width: Int, height: Int, hz: Double?) -> String {
        "\(width) × \(height)" + (hz.map { " · \(Int($0.rounded())) Hz" } ?? "")
    }

    private var subtitleText: String {
        guard let mode = display.currentMode else { return "" }
        return Self.subtitle(
            width: Int(mode.width), height: Int(mode.height),
            hz: mode.refreshRate > 0 ? mode.refreshRate : nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FBDTheme.spacingM) {
            header
            BrightnessSliderView(display: display)
                .accessibilityIdentifier("home.brightness.\(display.id)")
            if model.showsVolume(for: display) {
                FDBSlider(
                    value: Binding(
                        get: { volume ?? 0.5 },
                        set: { volume = $0; scheduleVolumeWrite($0) }
                    ),
                    in: 0...1,
                    accessibilityLabel: String(localized: "Volume for \(display.name)"),
                    valueText: { "\(Int(($0 * 100).rounded()))%" },
                    endSymbols: ("speaker", "speaker.wave.3")
                )
            }
        }
        .padding(.horizontal, FBDTheme.spacingM)
        .padding(.vertical, FBDTheme.spacingS)
        .background(
            RoundedRectangle(cornerRadius: FBDTheme.radiusCard, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? FBDTheme.panelBandOpacity : 0))
        )
        .onHover { isHovering = $0 }
        .fbdDisableDisplayConfirmation(isPresented: $confirmingDisable, display: display)
        .onAppear {
            model.probeVolume(for: display)
            if display.ddcAvailable {
                DisplayController.shared.readDDCState(for: display) { volume = $0.volume }
            }
        }
    }

    private var header: some View {
        HStack(spacing: FBDTheme.spacingM) {
            Image(systemName: DisplayKind(display: display).icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(display.name)
                    .font(FBDTheme.Font.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !subtitleText.isEmpty {
                    Text(subtitleText)
                        .font(FBDTheme.Font.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: FBDTheme.spacingM)
            if Settings.enableDisconnectOption {
                Button {
                    if display.isOnline {
                        confirmingDisable = true
                    } else {
                        _ = DisconnectController().setEnabled(true, displayID: display.id)
                    }
                } label: {
                    Image(systemName: "power")
                }
                .fbdGlassButton()
                .controlSize(.small)
                .help(display.isOnline ? "Disable display" : "Re-enable display")
                .accessibilityLabel(display.isOnline ? "Disable display" : "Re-enable display")
            }
            Button {
                model.open(.display(display.id))
            } label: {
                Image(systemName: "chevron.right")
            }
            .fbdGlassButton()
            .controlSize(.small)
            .accessibilityLabel(display.name)
            .accessibilityIdentifier("home.display.\(display.id)")
        }
    }

    /// Trailing-debounced DDC write (120 ms), as in `DDCPanelView`: only the
    /// value the drag settles on is sent.
    private func scheduleVolumeWrite(_ newValue: Double) {
        pendingVolumeWrite?.cancel()
        let display = display
        let item = DispatchWorkItem {
            Task { @MainActor in DisplayController.shared.setVolume(newValue, on: display) }
        }
        pendingVolumeWrite = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: item)
    }
}
