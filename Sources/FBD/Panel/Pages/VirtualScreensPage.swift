import FBDCore
import SwiftUI

struct VirtualScreensPage: View {
    @ObservedObject var model: PanelModel
    var body: some View { Text(verbatim: "Virtual Screens") }
}

// MARK: - Resolution presets

extension VirtualScreensPage {
    /// Built-in presets for the virtual-screen resolution picker.
    struct VirtualScreenPreset: Hashable, Identifiable {
        let width: UInt32
        let height: UInt32
        var id: String { label }
        var label: String { "\(width)×\(height)" }
    }

    static let resolutionPresets: [VirtualScreenPreset] = [
        VirtualScreenPreset(width: 1920, height: 1080),
        VirtualScreenPreset(width: 2560, height: 1440),
        VirtualScreenPreset(width: 3456, height: 2234),
        VirtualScreenPreset(width: 3840, height: 2160),
    ]
}
