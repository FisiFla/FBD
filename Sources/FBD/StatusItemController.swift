import AppKit
import os
import SwiftUI

/// Owns the NSStatusItem and the popover hosting the SwiftUI root view.
/// Popover-only (no menu fallback) — click toggles the popover, transient
/// behavior closes it on outside clicks.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "StatusItem")

    override init() {
        super.init()
        popover.behavior = .transient
        installRoot()
    }

    /// Host the SwiftUI root and size the popover from the view's fitting size
    /// (the root view declares min/ideal/max widths), clamped so content never
    /// gets clipped and the popover never becomes unwieldy.
    private func installRoot() {
        let hosting = NSHostingController(rootView: DisplayListView())
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        popover.contentViewController = hosting
        popover.contentSize = NSSize(
            width: min(max(fitting.width, 360), 480),
            height: min(max(fitting.height, 240), 720)
        )
    }

    /// Configure the status item (called once from AppCore.start()).
    func install() {
        guard let button = statusItem.button else {
            log.error("No status item button available")
            return
        }
        let image = NSImage(systemSymbolName: "display", accessibilityDescription: "FBD")
            ?? NSImage(systemSymbolName: "sun.max", accessibilityDescription: "FBD")
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = "FBD"
    }

    /// Refresh the hosted SwiftUI root after displays changed. When the
    /// popover is open the view refreshes itself via notifications, so only
    /// rebuild while closed to avoid clobbering in-flight interaction.
    func refreshUI() {
        guard !popover.isShown else { return }
        installRoot()
    }

    func showPopover() {
        guard let button = statusItem.button else {
            log.error("No status item button available")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }
}
