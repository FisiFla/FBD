import AppKit
import os
import SwiftUI

/// Owns the NSStatusItem and a floating NSPanel hosting the SwiftUI root view
/// (BetterDisplay-style, no popover). The panel has a standard title bar with
/// a close button, is resizable within min/max bounds, remembers its frame,
/// and never activates the app.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: NSPanel
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "StatusItem")
    private var escapeMonitor: Any?
    /// Right-click context menu (left-click toggles the panel).
    private var contextMenu: NSMenu?
    /// Whether the panel has been shown at least once this session.
    private var hasShownPanel = false
    /// Whether an autosaved frame existed at launch (restored by
    /// setFrameAutosaveName); when true the panel keeps that position.
    private let hasRestoredFrame: Bool

    override init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 650),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "FBD"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 420, height: 500)
        panel.maxSize = NSSize(width: 600, height: 900)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // Remembers position/size across launches and shows.
        panel.setFrameAutosaveName("FBDMainPanel")
        hasRestoredFrame = UserDefaults.standard.string(forKey: "NSWindow Frame FBDMainPanel") != nil
        let hosting = NSHostingController(rootView: DisplayListView())
        panel.contentViewController = hosting
        // Assigning a contentViewController resizes the window to the view's
        // fitting size; enforce the designed default afterwards.
        panel.setContentSize(NSSize(width: 460, height: 650))
        self.panel = panel
        super.init()
        panel.delegate = self
        installEscapeMonitor()
        // In-content close button (header ×) posts this notification.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closeFromNotification(_:)),
            name: .fbdPanelCloseRequested,
            object: nil
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
        button.action = #selector(togglePanel(_:))
        button.toolTip = "FBD"
        button.setAccessibilityLabel("FBD — display control")
        // Right-click opens a context menu; left-click toggles the panel.
        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show FBD", action: #selector(togglePanel(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit FBD", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        contextMenu = menu
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// The SwiftUI root refreshes itself from @Published/notification-driven
    /// state, so there is nothing to rebuild when displays change. Kept as a
    /// stable hook for AppCore's existing call sites.
    func refreshUI() {}

    /// Show the panel: anchored below the status item on first show,
    /// otherwise at the last used position (autosave).
    func showPanel() {
        guard let button = statusItem.button else {
            log.error("No status item button available")
            return
        }
        // Anchor below the status item only on the very first show of a
        // fresh install (no autosaved frame). Re-position AFTER ordering
        // front so a deferred autosave restore cannot override the anchor.
        let needsAnchor = !hasShownPanel && !hasRestoredFrame
        hasShownPanel = true
        panel.makeKeyAndOrderFront(nil)
        if needsAnchor {
            let width = panel.frame.width
            let top: CGFloat
            let rightX: CGFloat
            if let buttonWindow = button.window {
                top = buttonWindow.frame.minY - 4
                rightX = buttonWindow.frame.maxX - 8
            } else if let screen = NSScreen.main {
                top = screen.visibleFrame.maxY - 4
                rightX = screen.visibleFrame.maxX - 8
            } else {
                return
            }
            panel.setFrameTopLeftPoint(NSPoint(x: rightX - width, y: top))
        }
    }

    func closePanel() {
        panel.orderOut(nil)
    }

    // MARK: - Actions

    @objc private func closeFromNotification(_ sender: Any?) {
        closePanel()
    }

    @objc private func togglePanel(_ sender: Any?) {
        // Right-click: show the context menu instead of toggling.
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    @objc private func openSettings(_ sender: Any?) {
        showPanel()
        NotificationCenter.default.post(name: .fbdOpenSettings, object: nil)
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func showContextMenu() {
        guard let button = statusItem.button, let contextMenu else { return }
        contextMenu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
    }

    /// Escape closes the panel. A local monitor is used because the panel is
    /// non-activating and may not be key while visible.
    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.panel.isVisible else {
                return event
            }
            self.closePanel()
            return nil
        }
    }

    // MARK: - NSWindowDelegate

    /// cmd+W and the title-bar close button: hide instead of closing the
    /// window object (the panel is reused for the app's lifetime).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closePanel()
        return false
    }
}
