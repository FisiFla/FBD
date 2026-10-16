import FBDCore
import SwiftUI

struct HomePage: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: FBDTheme.spacingL) {
            if model.displays.isEmpty {
                Text("No displays")
                    .font(FBDTheme.Font.secondary)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(model.displays) { DisplayBlock(model: model, display: $0) }
            }
            Divider()
            QuickTogglesRow(model: model)
            Divider()
            PresetsSection(model: model)
            Divider()
            NavigationRows(model: model)
            Divider()
            PanelFooter()
        }
    }
}
