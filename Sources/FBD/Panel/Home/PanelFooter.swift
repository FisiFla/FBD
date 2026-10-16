import AppKit
import FBDCore
import SwiftUI

struct PanelFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Posted rather than calling the window controller, so the popover closes too.
            FBDListRow(symbol: "gearshape", title: "Settings…") {
                NotificationCenter.default.post(name: .fbdOpenSettings, object: nil)
            }
                .accessibilityIdentifier("home.settings")
            FBDListRow(symbol: "arrow.down.circle", title: "Check for Updates") {
                UpdaterController.shared.checkForUpdates()
            }
            FBDListRow(symbol: "power", title: "Quit FBD") { NSApp.terminate(nil) }
        }
    }
}
