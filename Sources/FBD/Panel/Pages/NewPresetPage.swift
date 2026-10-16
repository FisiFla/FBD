import FBDCore
import SwiftUI

struct NewPresetPage: View {
    @ObservedObject var model: PanelModel
    let display: Display
    var body: some View { Text(verbatim: "New Preset") }
}
