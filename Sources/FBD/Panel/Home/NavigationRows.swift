import SwiftUI

struct NavigationRows: View {
    @ObservedObject var model: PanelModel

    static func countText(_ n: Int) -> String { n == 0 ? String(localized: "None") : "\(n)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FBDListRow(
                symbol: "rectangle.on.rectangle", title: "Virtual Screens",
                value: Self.countText(model.virtualScreenCount), showsChevron: true
            ) { model.open(.virtualScreens) }
            FBDListRow(
                symbol: "square.grid.2x2", title: "Display Groups",
                value: Self.countText(model.groupCount), showsChevron: true
            ) { model.open(.groups) }
        }
    }
}
