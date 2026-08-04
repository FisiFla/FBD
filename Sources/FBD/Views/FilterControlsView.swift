import FBDCore
import SwiftUI

/// Full-screen software filter controls (contrast / saturation / gamma /
/// color temperature / invert). Shown in a "Filters" disclosure row — sliders
/// inside menus are fragile; a disclosure row matches the card's other
/// sections.
///
/// Owns the filter parameter state and the apply/reset round-trip through
/// DisplayController.
@MainActor
struct FilterControlsView: View {
    @ObservedObject var display: Display

    @State private var filterParams = ScreenFilterParams.neutral

    var body: some View {
        filterControls
    }

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
}
