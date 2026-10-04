import AppKit
import FBDCore
import SwiftUI

/// Full-screen software filter controls (contrast / saturation / gamma /
/// color temperature / invert / sharpening / geometry / 3D LUT). Shown in a
/// "Filters" disclosure row — sliders inside menus are fragile; a disclosure
/// row matches the card's other sections.
///
/// Owns the filter parameter state and the apply/reset round-trip through
/// DisplayController.
@MainActor
struct FilterControlsView: View {
    @ObservedObject var display: Display

    @State private var filterParams = ScreenFilterParams.neutral
    @State private var cornerRadius: Double = 0

    var body: some View {
        filterControls
            .onAppear {
                // Persisted per display; 0 (the default, for any display the
                // user never touched) spawns no mask at all.
                cornerRadius = Settings.cornerRadius(for: display.identityKey)
            }
    }

    /// Rounded-corner mask radius. Persisted per display identity, and 0 removes
    /// the mask outright rather than leaving an empty window on screen. Drawn,
    /// not captured — so it needs no Screen Recording grant.
    private var cornerRadiusBinding: Binding<Double> {
        Binding(
            get: { cornerRadius },
            set: { value in
                cornerRadius = value
                DisplayController.shared.setCornerRadius(value, on: display)
            }
        )
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

    private var filterSharpness: Binding<Double> {
        Binding(
            get: { filterParams.sharpness },
            set: { filterParams.sharpness = $0; applyScreenFilter() }
        )
    }

    private var filterUnsharpRadius: Binding<Double> {
        Binding(
            get: { filterParams.unsharpRadius },
            set: { filterParams.unsharpRadius = $0; applyScreenFilter() }
        )
    }

    private var filterZoom: Binding<Double> {
        Binding(
            get: { filterParams.zoom },
            set: { filterParams.zoom = $0; applyScreenFilter() }
        )
    }

    private var filterOffsetX: Binding<Double> {
        Binding(
            get: { filterParams.offsetX },
            set: { filterParams.offsetX = $0; applyScreenFilter() }
        )
    }

    private var filterOffsetY: Binding<Double> {
        Binding(
            get: { filterParams.offsetY },
            set: { filterParams.offsetY = $0; applyScreenFilter() }
        )
    }

    /// The pan margin the current zoom leaves — mirrors the clamp in
    /// `ScreenFilterParams.init`, so the sliders cannot show a value the
    /// parameter model would silently reduce.
    private var panLimit: Double {
        (1 - 1 / filterParams.zoom) / 2
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

    private func chooseLUT() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a .cube 3D LUT"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        filterParams.lutPath = url.path
        applyScreenFilter()
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: FBDTheme.spacingS) {
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

            Divider()
            Slider(value: filterSharpness, in: 0...ScreenFilterParams.maxSharpness, step: 0.1) {
                Text("Sharpness")
            } minimumValueLabel: {
                Text("Off")
            } maximumValueLabel: {
                Text("\(Int(ScreenFilterParams.maxSharpness))")
            }
            .font(.caption)
            if filterParams.sharpness > 0 {
                Slider(value: filterUnsharpRadius, in: 0...ScreenFilterParams.maxUnsharpRadius, step: 0.5) {
                    Text("Radius (px)")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("\(Int(ScreenFilterParams.maxUnsharpRadius))")
                }
                .font(.caption)
            }

            Divider()
            Slider(value: filterZoom, in: 1...4, step: 0.05) {
                Text("Zoom")
            } minimumValueLabel: {
                Text("1x")
            } maximumValueLabel: {
                Text("4x")
            }
            .font(.caption)
            if filterParams.zoom > 1 {
                Slider(value: filterOffsetX, in: -panLimit...panLimit, step: 0.005) {
                    Text("Pan Horizontal")
                }
                .font(.caption)
                Slider(value: filterOffsetY, in: -panLimit...panLimit, step: 0.005) {
                    Text("Pan Vertical")
                }
                .font(.caption)
            }

            Divider()
            HStack(spacing: FBDTheme.spacingM) {
                Button(filterParams.lutPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose LUT…") {
                    chooseLUT()
                }
                .controlSize(.small)
                if filterParams.lutPath != nil {
                    Button("Clear LUT") {
                        filterParams.lutPath = nil
                        applyScreenFilter()
                    }
                    .controlSize(.small)
                }
            }

            Divider()
            Slider(value: cornerRadiusBinding, in: 0...120, step: 1) {
                Text("Rounded Corners")
            } minimumValueLabel: {
                Text("Off")
            } maximumValueLabel: {
                Text("\(Int(cornerRadius))px")
            }
            .font(.caption)

            Button("Reset") {
                resetScreenFilter()
            }
            .controlSize(.small)
        }
    }
}
