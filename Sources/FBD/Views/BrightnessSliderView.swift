import FBDCore
import SwiftUI

/// Brightness slider bound to `display.brightness`, routed through
/// DisplayController (which owns debouncing — never debounce here).
@MainActor
struct BrightnessSliderView: View {
    @ObservedObject var display: Display

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.min")
                .foregroundStyle(.secondary)
            if let brightness = display.brightness {
                Text("0%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { display.brightness ?? 0 },
                        set: { DisplayController.shared.setBrightness($0, on: display) }
                    ),
                    in: 0...1
                )
                Text("100%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(Int((brightness * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            } else {
                Text("Brightness unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
