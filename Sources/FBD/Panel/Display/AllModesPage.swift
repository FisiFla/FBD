import FBDCore
import SwiftUI

struct AllModesPage: View {
    @ObservedObject var model: PanelModel
    let display: Display
    var body: some View { Text(verbatim: "All Modes") }
}
