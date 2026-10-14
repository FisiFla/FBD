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
        if let window, let hostingView, let background = window.contentView,
           isReusable(background: background, style: style) {
            hostingView.rootView = content
            apply(style, to: window, background: background)
            position(window, on: screen, style: style)
            return window
        }
        // Glass and vibrancy are different view classes, so a style change between them rebuilds.
        // Order the old one out first: it is still on screen otherwise, and the new HUD would sit
        // on top of the one it replaced.
        window?.orderOut(nil)

        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false

        // Rounded HUD background: the style's material, or the OS's glass where the style asks for
        // it and the OS has it.
        //
        // The vibrancy path is `.withinWindow`, which means the material samples the window's *own*
        // content — and this window holds only the SwiftUI content, so in practice it renders as a
        // flat fill rather than sampling the desktop behind it. `.behindWindow` is not a substitute:
        // it was measured on macOS 27 and the HUD did not appear at all. `NSGlassEffectView`
        // (macOS 26+) is the way to sample the backdrop, which is why it is offered as a style
        // rather than applied to everyone. See the Crisp review's rule 9.
        let background: NSView
        if style.background == .glass, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.wantsLayer = true
            glass.layer?.masksToBounds = true
            background = glass
        } else {
            let effectView = NSVisualEffectView()
            effectView.state = .active
            effectView.blendingMode = .withinWindow
            effectView.wantsLayer = true
            effectView.layer?.masksToBounds = true
            background = effectView
        }
        apply(style, to: window, background: background)

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        install(hostingView, in: background)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: background.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        window.contentView = background
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

    /// Apply the parts of the style the *window* owns — the background material or glass, the
    /// corner radius and the shadow — as opposed to what the SwiftUI content draws. Also used when
    /// reusing a window, so a style change takes effect without tearing the HUD down.
    private func apply(_ style: OSDStyle, to window: NSWindow, background: NSView) {
        if let effectView = background as? NSVisualEffectView {
            switch style.background {
            case .hudDark:
                effectView.material = .hudWindow
            case .adaptive:
                // Lets the material follow the system appearance instead of forcing
                // the dark HUD in light mode.
                effectView.material = .popover
            case .glass:
                // Unreachable while `isReusable` holds — a glass style never reuses a vibrancy
                // view — and the sensible fallback for a macOS without glass.
                effectView.material = .hudWindow
            }
        }
        background.layer?.cornerRadius = CGFloat(style.cornerRadius)
        applyGlassCornerRadius(CGFloat(style.cornerRadius), to: background)
        window.hasShadow = style.showsShadow
    }

    // MARK: - The macOS 26 glass boundary
    //
    // `NSGlassEffectView` needs macOS 26 and this package deploys to 13, so the type may not appear
    // in a signature. These three helpers keep the availability check in one place each and expose
    // only `Void` and `Bool`, which lets the callers stay unannotated.

    /// Whether this background is the OS's glass.
    private func isGlass(_ background: NSView) -> Bool {
        if #available(macOS 26.0, *) {
            return background is NSGlassEffectView
        }
        return false
    }

    /// Set the glass corner radius, where the background is glass.
    private func applyGlassCornerRadius(_ radius: CGFloat, to background: NSView) {
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.cornerRadius = radius
        }
    }

    /// Put the SwiftUI content inside the background: in the glass's `contentView`, which the header
    /// guarantees is placed inside the effect, and as a plain subview otherwise.
    private func install(_ hostingView: NSView, in background: NSView) {
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.contentView = hostingView
        } else {
            background.addSubview(hostingView)
        }
    }

    /// Whether an existing background view can carry this style. Glass and vibrancy are different
    /// view classes, so switching between them needs a new window rather than a restyled one.
    private func isReusable(background: NSView, style: OSDStyle) -> Bool {
        switch style.background {
        case .glass: return isGlass(background)
        case .hudDark, .adaptive: return background is NSVisualEffectView
        }
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
