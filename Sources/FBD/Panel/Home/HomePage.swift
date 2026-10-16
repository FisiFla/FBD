import FBDCore
import SwiftUI

struct HomePage: View {
    @ObservedObject var model: PanelModel
    var body: some View { Text(verbatim: "Home") }
}
