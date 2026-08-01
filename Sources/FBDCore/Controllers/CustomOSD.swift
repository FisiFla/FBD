import AppKit
import CoreGraphics
import SwiftUI
import os

/// Transient brightness/volume HUD shown near the top of the screen.
///
/// A borderless, mouse-transparent, SwiftUI-backed `NSWindow` (dark
/// `NSVisualEffectView` with the `.hudWindow` material) centered under the
/// menu bar of the target display (or the display containing the cursor).
/// Auto-hides after 1.2 s; a new `show` resets the timer. No-op while
/// `Settings.customOSDEnabled` is false.
@MainActor
public final class CustomOSD {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "CustomOSD")

    /// How long the HUD stays visible after the last `show`.
    private static let hideDelay: TimeInterval = 1.2
    /// Corner radius of the HUD's dark background.
    private static let cornerRadius: CGFloat = 12

    private var window: NSWindow?
    private var hostingView: NSHostingView<OSDContent>?
    private var hideWorkItem: DispatchWorkItem?

    public init() {}

    deinit {
        hideWorkItem?.cancel()
    }

    /// True while the HUD is on screen.
    public var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Show a transient brightness/volume HUD near the menu bar.
    /// icon: "sun.max" / "speaker.wave.2" / "speaker.slash"; value 0…1
    /// (clamped). `displayID` selects the display; nil shows on the display
    /// containing the cursor.
    public func show(icon: String, value: Double, displayID: CGDirectDisplayID? = nil) {
        guard Settings.customOSDEnabled else { return }
        let clamped = min(max(value, 0), 1)
        guard let screen = targetScreen(displayID: displayID) else {
            log.warning("show: no screen found (display \(displayID.map(String.init) ?? "cursor"))")
            return
        }

        let window = makeWindow(content: OSDContent(icon: icon, value: clamped), on: screen)
        self.window = window

        // Reset the auto-hide timer on every show.
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.hide()
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: workItem)

        window.orderFrontRegardless()
    }

    /// Dismiss immediately.
    public func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        window?.orderOut(nil)
    }

    // MARK: - Window plumbing

    /// Reuse the existing window when present (just swap the SwiftUI content
    /// and reposition); otherwise build the borderless HUD window.
    private func makeWindow(content: OSDContent, on screen: NSScreen) -> NSWindow {
        if let window, let hostingView {
            hostingView.rootView = content
            position(window, on: screen)
            return window
        }

        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false

        // Dark rounded HUD background: NSVisualEffectView with the HUD material.
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .withinWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = Self.cornerRadius
        effectView.layer?.masksToBounds = true

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
        window.contentView = effectView
        self.hostingView = hostingView

        // Size the window to the SwiftUI content's fitting size (fall back to a
        // sane HUD size if the hosting view has not measured yet).
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        window.setContentSize(NSSize(
            width: fitting.width > 0 ? fitting.width : 180,
            height: fitting.height > 0 ? fitting.height : 44
        ))
        position(window, on: screen)
        return window
    }

    /// Center the window horizontally, just under the menu bar of the screen.
    private func position(_ window: NSWindow, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 8
        ))
    }

    /// The screen to show on: the requested display, else the screen under the
    /// cursor, else the main screen.
    private func targetScreen(displayID: CGDirectDisplayID?) -> NSScreen? {
        if let displayID,
           let screen = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
           }) {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main
    }
}

/// The HUD's SwiftUI content: icon + progress bar + percentage.
private struct OSDContent: View {
    let icon: String
    let value: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 24)
            ProgressView(value: value)
                .frame(width: 110)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
