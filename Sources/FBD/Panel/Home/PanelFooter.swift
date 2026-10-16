import AppKit
import FBDCore
import SwiftUI

struct PanelFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FBDListRow(symbol: "gearshape", title: "Settings…") { SettingsWindowController.shared.show() }
                .accessibilityIdentifier("home.settings")
            FBDListRow(symbol: "arrow.down.circle", title: "Check for Updates") {
                UpdaterController.shared.checkForUpdates()
            }
            FBDListRow(symbol: "power", title: "Quit FBD") { NSApp.terminate(nil) }
        }
    }
}
