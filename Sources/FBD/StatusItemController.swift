import AppKit
import FBDCore
import os
import SwiftUI

/// The popover's window: borderless, so it must opt in to key status for sliders, text
/// fields and the Escape monitor to work.
final class FBDPopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the NSStatusItem and a borderless, Control Center–style panel hosting the
/// page stack (`PanelRootView`). The panel sits under the status item, sizes itself
/// to its content (capped by `PanelSizing`), closes on a click outside or Escape,
/// and never activates the app. Settings lives in its own window
/// (`SettingsWindowController`).
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: NSPanel
    private let model: PanelModel
    private let hosting: PanelHostingView<PanelRootView>
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "StatusItem")
    private var escapeMonitor: Any?
    /// Closes the panel on a click in another app; installed only while it is visible.
    private var outsideClickMonitor: Any?
    /// Coalesces content-size changes into one resize per runloop turn.
    private var fitScheduled = false
    /// Right-click context menu (left-click toggles the panel).
    private var contextMenu: NSMenu?

    /// Gap between the status item and the panel's top edge.
    private static let anchorGap: CGFloat = 6
    /// Minimum distance from the panel to the screen's visible edges.
    private static let screenMargin: CGFloat = 8
    private static let cornerRadius: CGFloat = 16

    override init() {
        let panel = FBDPopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: FBDTheme.panelWidth, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let model = PanelModel.live()
        let hosting = PanelHostingView(rootView: PanelRootView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = Self.makeBackdrop(containing: hosting, size: panel.frame.size)
        self.model = model
        self.hosting = hosting
        self.panel = panel
        super.init()
        panel.delegate = self
        hosting.onContentHeightChange = { [weak self] in self?.scheduleFit() }
        installEscapeMonitor()
        let center = NotificationCenter.default
        // Settings opens in its own window; the popover gets out of the way.
        center.addObserver(self, selector: #selector(closeFromNotification(_:)), name: .fbdOpenSettings, object: nil)
        // Settings is where the status item's icon and visibility are edited.
        center.addObserver(self, selector: #selector(settingsClosed(_:)), name: .fbdSettingsClosed, object: nil)
    }

    /// The panel's backdrop: system glass where this macOS has it (and glass isn't disabled),
    /// else the popover material. The hosting view is its content.
    private static func makeBackdrop(containing content: NSView, size: NSSize) -> NSView {
        let bounds = NSRect(origin: .zero, size: size)
        content.frame = bounds
        if FBDGlass.isAvailable && OSDGlass.isAvailable, let glass = OSDGlass.makeView(cornerRadius: cornerRadius) {
            glass.frame = bounds
            glass.autoresizingMask = [.width, .height]
            OSDGlass.setContent(content, in: glass)
            return glass
        }
        let effect = NSVisualEffectView(frame: bounds)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return effect
    }

    @objc private func settingsClosed(_ sender: Any?) {
        applyStatusItemAppearance()
    }

    // MARK: - Sizing and placement

    private func scheduleFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        // Resizing the window from inside SwiftUI's own layout pass re-enters it; wait a turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitScheduled = false
            self.fitToContent()
        }
    }

    /// Height = the page's ideal height, capped by the screen; the top edge stays put.
    private func fitToContent() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let height = PanelSizing.height(
            content: hosting.intrinsicContentSize.height,
            screenVisibleHeight: screen.visibleFrame.height
        )
        guard abs(height - panel.frame.height) >= 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size = NSSize(width: FBDTheme.panelWidth, height: height)
        panel.setFrame(frame, display: true)
        // A borderless window's shadow follows its content's alpha; recompute it for the new shape.
        panel.invalidateShadow()
    }

    /// Top edge `anchorGap` below the status item, centred on it, kept inside the screen.
    private func anchoredFrame() -> NSRect? {
        guard let button = statusItem.button, let buttonWindow = button.window else { return nil }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = buttonWindow.screen ?? NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        let width = FBDTheme.panelWidth
        let height = PanelSizing.height(
            content: hosting.intrinsicContentSize.height,
            screenVisibleHeight: visible.height
        )
        let top = min(buttonRect.minY - Self.anchorGap, visible.maxY)
        let minX = visible.minX + Self.screenMargin
        let maxX = visible.maxX - Self.screenMargin - width
        let x = min(max(buttonRect.midX - width / 2, minX), maxX)
        return NSRect(x: x, y: top - height, width: width, height: height)
    }

    /// Configure the status item (called once from AppCore.start()).
    func install() {
        guard let button = statusItem.button else {
            log.error("No status item button available")
            return
        }
        applyStatusItemAppearance()
        button.target = self
        button.action = #selector(togglePanel(_:))
        button.toolTip = "FBD"
        button.setAccessibilityLabel("FBD — display control")
        // Right-click opens a context menu; left-click toggles the panel.
        let menu = NSMenu()
        let showItem = NSMenuItem(title: NSLocalizedString("Show FBD", comment: ""), action: #selector(togglePanel(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        let settingsItem = NSMenuItem(title: NSLocalizedString("Settings…", comment: ""), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let updateItem = NSMenuItem(title: NSLocalizedString("Check for Updates…", comment: ""), action: #selector(checkForUpdates(_:)), keyEquivalent: "u")
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: NSLocalizedString("Quit FBD", comment: ""), action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        contextMenu = menu
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// The SwiftUI root refreshes itself from @Published/notification-driven
    /// state, so there is nothing to rebuild when displays change. It is the
    /// right hook for the status item's own appearance, though: whether the item
    /// is shown depends on how many displays are attached.
    func refreshUI() {
        applyStatusItemAppearance()
    }

    /// Apply the stored icon and the visibility policy.
    ///
    /// Called at install time, from `refreshUI()` (AppCore's display observers),
    /// and from `settingsClosed` — the Settings window is where both values are
    /// edited, so leaving it is the moment they can have changed.
    ///
    /// The fallback chain is the point: this item is a menu-bar app's only
    /// permanent surface, so a stored symbol name that fails to resolve degrades
    /// to a known-good icon rather than leaving the button blank.
    private func applyStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: Settings.menuBarIcon.symbolName,
            accessibilityDescription: "FBD"
        ) ?? NSImage(
            systemSymbolName: MenuBarIconStyle.default.symbolName,
            accessibilityDescription: "FBD"
        )
        image?.isTemplate = true
        button.image = image
        statusItem.isVisible = MenuBarIconPolicy.isStatusItemVisible(
            hideWhenSingleDisplay: Settings.hideMenuBarIconWhenSingleDisplay,
            hasExternalDisplay: DisplayController.shared.displays.contains { !$0.isBuiltin },
            showDockIcon: Settings.showDockIcon
        )
    }

    /// Show the panel under the status item.
    func showPanel() {
        // The hosting view lives as long as the app, so `onAppear` does not fire again on each
        // open: re-read the state that can change while the popover is closed (Dark Mode, Night
        // Shift, True Tone, Keep Awake; virtual-screen and group counts) before sizing it.
        model.refreshToggles()
        model.refreshCounts()
        if let frame = anchoredFrame() {
            panel.setFrame(frame, display: false)
        } else {
            log.error("No status item button available; showing the panel where it was")
        }
        panel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
    }

    func closePanel() {
        panel.orderOut(nil)
        removeOutsideClickMonitor()
        // Reopen on the home page.
        model.open(.home)
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        // Global monitors only see events bound for other apps: clicks on the status item and
        // inside the panel stay with their own handlers.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
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
        closePanel()
        SettingsWindowController.shared.show()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        UpdaterController.shared.checkForUpdates()
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
    ///
    /// It only acts on an Escape delivered to the panel itself: with the panel
    /// merely visible, the key may belong to an open/save panel, a sheet or
    /// confirmation dialog, or a text field (including IME composition), all of
    /// which use Escape to cancel their own thing.
    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.panel.isVisible,
                  event.window === self.panel, self.panel.attachedSheet == nil
            else {
                return event
            }
            if let text = self.panel.firstResponder as? NSTextView, text.hasMarkedText() {
                return event
            }
            self.closePanel()
            return nil
        }
    }

    // MARK: - NSWindowDelegate

    /// cmd+W: hide instead of closing the window object (the panel is reused
    /// for the app's lifetime).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closePanel()
        return false
    }
}

/// Reports when SwiftUI changes the page's ideal height, so the panel can follow it.
///
/// Neither obvious hook works: the view fills the panel, so its frame never grows on its own
/// (no frame-change notification), and `NSHostingView` updates its intrinsic size without going
/// through `invalidateIntrinsicContentSize()`. It does lay out on every content change, so the
/// height is compared there.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var onContentHeightChange: (() -> Void)?
    private var reportedHeight: CGFloat?

    override func layout() {
        super.layout()
        let height = intrinsicContentSize.height
        guard height != reportedHeight else { return }
        reportedHeight = height
        onContentHeightChange?()
    }
}
