import FBDCore
import SwiftUI

/// Brightness control bound to `display.brightness`, routed through
/// DisplayController (which owns debouncing — never debounce here).
///
/// On XDR-capable displays the slider shows a live nits estimate and a
/// zone divider at the hardware maximum — everything past it is the
/// software/XDR boost region.
@MainActor
struct BrightnessSliderView: View {
    @ObservedObject var display: Display

    /// "42" for 0.42 — broken out so the accessibility value stays
    /// type-checkable.
    private static func percentText(_ value: Double) -> Int {
        Int((value * 100).rounded())
    }

    var body: some View {
        if let brightness = display.brightness {
            HStack(spacing: 10) {
                Image(systemName: "sun.max")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                FDBSlider(
                    value: Binding(
                        get: { display.brightness ?? 0 },
                        set: { DisplayController.shared.setBrightness($0, on: display) }
                    ),
                    in: 0...1,
                    zoneFraction: xdrZoneFraction,
                    accessibilityLabel: "Brightness for \(display.name)",
                    valueText: { _ in "\(Self.percentText(display.brightness ?? 0)) percent" }
                )
                .accessibilityValue("\(Self.percentText(display.brightness ?? 0)) percent")

                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(Self.percentText(brightness))%")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                    if let nits = nitsEstimate {
                        Text("\(nits) nits")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(width: 52, alignment: .trailing)
            }
        } else {
            Label("Brightness unavailable", systemImage: "sun.max.trianglebadge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: XDR zone + nits estimate

    /// Fraction of the slider occupied by the hardware range, based on the
    /// display's first valid preset (nil for non-XDR displays).
    private var xdrZoneFraction: Double? {
        guard let preset = validPreset,
              preset.maxHDRLuminance > preset.maxSliderBrightness,
              preset.maxHDRLuminance > 0 else { return nil }
        return Double(preset.maxSliderBrightness) / Double(preset.maxHDRLuminance)
    }

    /// Estimated nits for the current slider position (hardware max +
    /// HDR headroom mapping). Shows on XDR displays with a valid preset.
    private var nitsEstimate: Int? {
        guard let preset = validPreset,
              preset.maxHDRLuminance > preset.minSliderBrightness else { return nil }
        let brightness = display.brightness ?? 0
        let nits = Double(preset.minSliderBrightness)
            + brightness * Double(preset.maxHDRLuminance - preset.minSliderBrightness)
        return Int(nits.rounded())
    }

    private var validPreset: XDRPreset? {
        display.presets.first { $0.isValid }
    }
}
