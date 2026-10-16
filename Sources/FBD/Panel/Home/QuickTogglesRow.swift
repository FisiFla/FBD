import SwiftUI

struct QuickTogglesRow: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        FBDGlassContainer(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(model.toggles) { t in
                    FBDToggleTile(
                        symbol: t.symbol, title: t.title, isOn: t.isOn,
                        isEnabled: t.isAvailable, disabledReason: t.unavailableReason
                    ) { model.toggle(t.id) }
                    .accessibilityIdentifier("home.toggle.\(t.id)")
                }
            }
        }
        .onAppear { model.refreshToggles() }
    }
}
