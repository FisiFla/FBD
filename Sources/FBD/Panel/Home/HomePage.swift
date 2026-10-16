import FBDCore
import SwiftUI

struct HomePage: View {
    @ObservedObject var model: PanelModel
    var body: some View { Text(verbatim: "Home") }

    /// Whether the Rosetta warning banner applies to this process.
    static var rosettaWarningActive: Bool {
        IOAVServiceAPI.isAppleSilicon && IOAVServiceAPI.isRunningUnderRosetta && Settings.showRosettaWarning
    }
}
