import CoreGraphics
import FBDCore
import SwiftUI

struct PresetsSection: View {
    @ObservedObject var model: PanelModel

    private var newPresetTarget: CGDirectDisplayID? {
        let main = CGMainDisplayID()
        return model.displays.contains { $0.id == main } ? main : model.displays.first?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Presets")
                .padding(.bottom, FBDTheme.spacingXS)
            ForEach(model.displays) { display in
                ForEach(model.presets(for: display)) { preset in
                    FBDListRow(
                        symbol: preset.symbol.rawValue,
                        verbatim: preset.name,
                        value: model.displays.count > 1 ? display.name : nil
                    ) { model.apply(preset, to: display) }
                }
            }
            if let target = newPresetTarget {
                FBDListRow(symbol: "plus", title: "New Preset…") { model.open(.newPreset(target)) }
            }
        }
    }
}
