import SwiftUI

/// The one place FBD touches Liquid Glass. macOS 26+ and a Swift 6.2 toolchain get the
/// system glass; anything else gets the material/translucent fallback, so no other file
/// needs an availability check.
enum FBDGlass {
    /// `FBD_DISABLE_GLASS=1` forces the fallback so the macOS 13–25 look can be checked on 26+.
    static var isAvailable: Bool {
        if ProcessInfo.processInfo.environment["FBD_DISABLE_GLASS"] == "1" { return false }
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }
}

extension View {
    /// Glass in `shape` (controls layer only — never on content rows).
    @ViewBuilder
    func fbdGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *), FBDGlass.isAvailable {
            self.glassEffect(Self.makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            fallbackGlass(in: shape, tint: tint)
        }
        #else
        fallbackGlass(in: shape, tint: tint)
        #endif
    }

    @ViewBuilder
    func fbdGlassButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *), FBDGlass.isAvailable {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        self.buttonStyle(.bordered)
        #endif
    }

    @ViewBuilder
    func fbdGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *), FBDGlass.isAvailable {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }

    #if compiler(>=6.2)
    /// Built outside the `@ViewBuilder` body: assignments there are parsed as view expressions.
    @available(macOS 26, *)
    private static func makeGlass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
    #endif

    private func fallbackGlass<S: Shape>(in shape: S, tint: Color?) -> some View {
        background(
            ZStack {
                shape.fill(.regularMaterial)
                if let tint { shape.fill(tint.opacity(0.85)) }
            }
        )
    }
}

/// Groups glass elements so they blend/morph together on macOS 26+; a plain stack before.
struct FBDGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *), FBDGlass.isAvailable {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}
