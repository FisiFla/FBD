import AppKit
import Foundation

/// The OS's glass background, reached **by name** rather than by type.
///
/// `NSGlassEffectView` is macOS 26+, and referencing it by name needs an SDK that has it. CI builds
/// with the macOS 15 SDK, where the type does not exist at all, so `#available(macOS 26, *)` did not
/// save the file: availability is a *runtime* question and the symbol is a *compile-time* one. Every
/// reference to the name failed to compile there, which is three red builds nobody noticed.
///
/// So the class is looked up at runtime and configured through KVC — the same way this codebase
/// reaches private AppKit and CoreBrightness classes — and nothing here mentions the type. On a macOS
/// without it, `isAvailable` is false and the caller falls back to the vibrancy material.
enum OSDGlass {
    /// The class object, when this macOS has one.
    private static var classObject: NSObject.Type? {
        NSClassFromString("NSGlassEffectView") as? NSObject.Type
    }

    /// True when a glass background can be made here.
    static var isAvailable: Bool { classObject != nil }

    /// A glass background view, or nil when this macOS has none. `cornerRadius` is applied now
    /// because the caller's later restyle path cannot name the property either.
    static func makeView(cornerRadius: CGFloat) -> NSView? {
        guard let glass = classObject?.init() as? NSView else { return nil }
        glass.wantsLayer = true
        glass.layer?.masksToBounds = true
        setCornerRadius(cornerRadius, on: glass)
        return glass
    }

    /// Whether a background view is the glass one — by class name, since the type cannot be named.
    static func isGlass(_ view: NSView) -> Bool {
        NSStringFromClass(type(of: view)) == "NSGlassEffectView"
    }

    static func setCornerRadius(_ radius: CGFloat, on view: NSView) {
        view.setValue(radius, forKey: "cornerRadius")
    }

    /// Put the content inside the glass. The SDK header is explicit that only `contentView` is
    /// guaranteed to sit inside the effect, so it goes there rather than in as a plain subview.
    static func setContent(_ content: NSView, in view: NSView) {
        view.setValue(content, forKey: "contentView")
    }
}
