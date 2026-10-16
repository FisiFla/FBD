import FBDCore
import SwiftUI

struct DisplayDetailPage: View {
    @ObservedObject var model: PanelModel
    let display: Display
    var body: some View { Text(verbatim: "Display") }
}
