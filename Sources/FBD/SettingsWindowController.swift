import AppKit
import SwiftUI

/// Settings in its own standard window (never inside the popover).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    /// Starts answering `.fbdOpenSettings`. A selector-based observer runs synchronously on the
    /// posting thread (always main here), without `MainActor.assumeIsolated`, which is macOS 14+.
    func startObserving() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings(_:)), name: .fbdOpenSettings, object: nil
        )
    }

    /// userInfo: `"tab"` (a page name, see `SettingsPage.named`) and `"displayID"` (an `NSNumber`).
    @objc private func openSettings(_ note: Notification) {
        let page = SettingsView.SettingsPage.named(note.userInfo?["tab"] as? String)
        let id = (note.userInfo?["displayID"] as? NSNumber)?.uint32Value
        show(page: page, displayID: id)
    }

    func show(page: SettingsView.SettingsPage = .displays, displayID: CGDirectDisplayID? = nil) {
        let root = SettingsView(targetDisplayID: displayID, initialPage: page)
        if let window {
            // Assigning a content view controller resizes the window to the view's fitting size;
            // keep the frame the user left it at.
            let frame = window.frame
            window.contentViewController = NSHostingController(rootView: root)
            window.setFrame(frame, display: false)
        } else {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.title = String(localized: "FBD Settings")
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("FBDSettingsWindow")
            w.contentViewController = NSHostingController(rootView: root)
            w.delegate = self
            if !w.setFrameUsingName("FBDSettingsWindow") {
                w.setContentSize(NSSize(width: 760, height: 600))
                w.center()
            }
            window = w
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    // MARK: - NSWindowDelegate

    /// Settings is where the status item's icon and visibility are edited, so leaving it is
    /// when they can have changed; `StatusItemController` re-applies them on this.
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .fbdSettingsClosed, object: nil)
    }
}
