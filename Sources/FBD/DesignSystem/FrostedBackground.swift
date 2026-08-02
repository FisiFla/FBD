import AppKit
import SwiftUI

/// Frosted-glass panel background (NSVisualEffectView) for the floating
/// panel — the Control Center / Raycast look. The NSPanel is made
/// transparent (isOpaque = false) and this view provides the blur.
struct FrostedBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
