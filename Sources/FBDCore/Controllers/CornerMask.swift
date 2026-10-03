import CoreGraphics

/// Geometry for the rounded-corner mask: a black sheet with a rounded-rectangle
/// hole, so only the corners outside the rounded shape are painted.
///
/// Pure by design — the window plumbing that consumes it is untestable, the
/// arithmetic is not.
public enum CornerMask {
    /// The radius actually usable on a display of this size. Returns 0 when the
    /// radius is not positive or the size is degenerate, which callers read as
    /// "no mask": an absent overlay, not a zero-radius one.
    ///
    /// Clamped to **half the shorter side**. Past that the rounded rectangle
    /// stops being a rectangle — its corner arcs meet and then overlap — so a
    /// larger request is capped rather than drawn wrong.
    public static func clampedRadius(_ radius: Double, in size: CGSize) -> Double {
        guard radius > 0, size.width > 0, size.height > 0 else { return 0 }
        return min(radius, Double(min(size.width, size.height)) / 2)
    }

    /// A path covering everything **outside** a rounded rectangle of this size.
    ///
    /// Two subpaths — the full rect and the rounded rect — to be filled with the
    /// even-odd rule, which leaves exactly the four corner slivers.
    public static func path(size: CGSize, radius: Double) -> CGPath {
        let rect = CGRect(origin: .zero, size: size)
        let path = CGMutablePath()
        path.addRect(rect)
        path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        return path
    }
}
