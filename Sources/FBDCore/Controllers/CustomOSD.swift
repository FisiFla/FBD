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
        let style = OSDStyle.load()
        guard let screen = targetScreen(displayID: displayID) else {
            log.warning("show: no screen found (display \(displayID.map(String.init) ?? "cursor"))")
            return
        }

        let window = makeWindow(
            content: OSDContent(icon: icon, value: clamped, style: style),
            style: style,
            on: screen
        )
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

    /// Reuse the existing window when present (just swap the SwiftUI content,
    /// re-apply the style and reposition); otherwise build the borderless HUD
    /// window.
    private func makeWindow(content: OSDContent, style: OSDStyle, on screen: NSScreen) -> NSWindow {
        if let window, let hostingView, let effectView = window.contentView as? NSVisualEffectView {
            hostingView.rootView = content
            apply(style, to: window, effectView: effectView)
            position(window, on: screen, style: style)
            return window
        }

        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false

        // Rounded HUD background: NSVisualEffectView with the style's material.
        let effectView = NSVisualEffectView()
        effectView.state = .active
        effectView.blendingMode = .withinWindow
        effectView.wantsLayer = true
        effectView.layer?.masksToBounds = true
        apply(style, to: window, effectView: effectView)

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
        position(window, on: screen, style: style)
        return window
    }

    /// Apply the parts of the style the *window* owns — the background material,
    /// the corner radius and the shadow — as opposed to what the SwiftUI content
    /// draws. Also used when reusing a window, so a style change takes effect
    /// without tearing the HUD down.
    private func apply(_ style: OSDStyle, to window: NSWindow, effectView: NSVisualEffectView) {
        switch style.background {
        case .hudDark:
            effectView.material = .hudWindow
        case .adaptive:
            // Lets the material follow the system appearance instead of forcing
            // the dark HUD in light mode.
            effectView.material = .popover
        }
        effectView.layer?.cornerRadius = CGFloat(style.cornerRadius)
        window.hasShadow = style.showsShadow
    }

    /// Place the window on `screen` according to the style. The default (top
    /// centre, 8pt under the menu bar) is exactly what FBD has always done, so an
    /// untouched install is unchanged.
    private func position(_ window: NSWindow, on screen: NSScreen, style: OSDStyle) {
        let visible = screen.visibleFrame
        let size = window.frame.size
        let inset: CGFloat = 8
        let origin: NSPoint
        switch style.position {
        case .topCenter:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - inset)
        case .topLeading:
            origin = NSPoint(x: visible.minX + inset, y: visible.maxY - size.height - inset)
        case .topTrailing:
            origin = NSPoint(x: visible.maxX - size.width - inset, y: visible.maxY - size.height - inset)
        case .bottomCenter:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + inset)
        }
        window.setFrameOrigin(origin)
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

/// The HUD's SwiftUI content: icon + bar + percentage.
private struct OSDContent: View {
    let icon: String
    let value: Double
    let style: OSDStyle

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 24)
            bar
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // The content carries its own foreground. The HUD's dark material needs a
        // light one, and a background that follows the system appearance needs a
        // system-appearance one — the same content cannot serve both, and leaving
        // it to the default made the dark HUD unreadable in light mode.
        .foregroundStyle(style.background == .hudDark ? Color.white : Color.primary)
    }

    @ViewBuilder
    private var bar: some View {
        switch style.barStyle {
        case .continuous:
            ProgressView(value: value)
                .frame(width: 110)
        case .segmented:
            SegmentedBar(value: value, count: style.segmentCount)
                .frame(width: 110, height: 10)
        }
    }
}

/// A discrete bar: `count` segments filled to `value`.
///
/// Drawn rather than assembled from sliders, because the HUD ignores the mouse and
/// anything that looks interactive but is not is a lie.
private struct SegmentedBar: View {
    let value: Double
    let count: Int

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 2
            let total = geometry.size.width
            let segmentWidth = max((total - gap * CGFloat(count - 1)) / CGFloat(count), 1)
            let filled = Int((value * Double(count)).rounded())
            HStack(spacing: gap) {
                ForEach(0..<count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index < filled ? Color.accentColor : Color.primary.opacity(0.25))
                        .frame(width: segmentWidth)
                }
            }
        }
    }
}
