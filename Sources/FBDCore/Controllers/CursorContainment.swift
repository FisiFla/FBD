import CoreGraphics

/// Keeps the pointer out of a display, so a stream of that display never shows
/// a cursor that has wandered onto it (#14).
///
/// Experimental upstream (BetterDisplay 5.0.4+), so FBD gates it behind a
/// setting that says so, and the decision itself is pure here so the geometry
/// can be tested without moving anyone's pointer.
public enum CursorContainment {
    /// Where to push a pointer that has entered `forbidden`.
    ///
    /// Returns **nil when the pointer is already outside** the forbidden
    /// display — the overwhelmingly common case, and the one that must stay
    /// free so a user who has not opted in never notices anything.
    ///
    /// The pointer is pushed to the nearest edge of `fallback` (the union of
    /// the other displays), so it leaves the way it came in rather than
    /// teleporting across the desktop.
    public static func repelledPosition(
        cursor: CGPoint,
        forbidden: CGRect,
        fallback: CGRect
    ) -> CGPoint? {
        guard forbidden.contains(cursor) else { return nil }
        // A fallback with no area cannot receive the pointer; refusing is better
        // than warping it to a coordinate on no display at all.
        guard fallback.width >= 2, fallback.height >= 2 else { return nil }

        let candidates = [
            CGPoint(x: fallback.minX + 1, y: cursor.y),
            CGPoint(x: fallback.maxX - 1, y: cursor.y),
            CGPoint(x: cursor.x, y: fallback.minY + 1),
            CGPoint(x: cursor.x, y: fallback.maxY - 1),
        ]
        return candidates.min {
            distance($0, cursor) < distance($1, cursor)
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))
    }
}
