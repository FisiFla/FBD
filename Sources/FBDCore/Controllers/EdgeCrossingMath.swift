import CoreGraphics

/// Where the pointer should be put when it is pushed at a display's edge and the
/// neighbouring display does not line up with it (Crisp item 9).
///
/// **The problem.** macOS only lets the pointer cross between two displays where
/// they are actually adjacent, and it clamps the pointer to the displays' bounds.
/// Put a 1080-tall display beside a 1440-tall one and the pointer crosses freely
/// over the shared 1080 points; above that the shorter display's edge is a wall.
/// Nothing is wrong with the arrangement — the two displays are flush — but the
/// area beside the shorter one is dead space, so the pointer stops dead in it
/// instead of carrying on to the display that *is* there.
///
/// **The fix.** When the pointer is pushed at an edge and a neighbour's facing
/// edge meets that edge, it is moved to the neighbour's nearest point instead of
/// stopping: sideways when the displays merely differ in height, or up/down onto
/// the neighbour's edge when they are offset. A deliberate gap in the
/// arrangement is respected — edges that are not actually adjacent never move the
/// pointer — and neither does an aligned edge pass, which macOS already crosses
/// on its own, so that crossing is left exactly as it was.
///
/// **Pure.** A point in, a point out: nothing here moves anyone's pointer, so all
/// of it is testable. `EdgeCrossingController` supplies the display bounds and
/// the push, the same split `CursorContainment`/`CursorContainmentController` use.
///
/// Coordinates are global display coordinates — origin at the top left of the
/// main display, y increasing downwards — the space `CGDisplayBounds` reports
/// and `CGWarpMouseCursorPosition` expects.
public enum EdgeCrossingMath {
    /// How close counts as "at the edge" and as "these edges meet". A point of
    /// slack absorbs the sub-pixel rounding of scaled displays, whose adjacent
    /// bounds are usually equal but occasionally a fraction apart.
    public static let slack: CGFloat = 1

    /// The point to move the pointer to, or `nil` to leave it alone.
    ///
    /// - Parameters:
    ///   - point: the pointer, in global display coordinates.
    ///   - push: where the pointer is heading — the movement of the current
    ///     event. Only the direction is read, and a push of zero is ignored.
    ///   - displays: every display's bounds, in global display coordinates.
    ///   - slack: see `slack`.
    public static func landing(
        from point: CGPoint,
        push: CGVector,
        displays: [CGRect],
        slack: CGFloat = EdgeCrossingMath.slack
    ) -> CGPoint? {
        guard push.dx != 0 || push.dy != 0,
              let here = displayUnder(point, among: displays) else { return nil }

        // Of several neighbours that could take the pointer, the one that moves
        // it least wins — with displays of different sizes side by side, the
        // nearest edge is the one the user was aiming at.
        var best: (point: CGPoint, slide: CGFloat)?
        func offer(_ candidate: CGPoint, slide: CGFloat) {
            if let current = best, current.slide <= slide { return }
            best = (candidate, slide)
        }

        for other in displays where other != here && other.width > 0 && other.height > 0 {
            if push.dx > 0, point.x >= here.maxX - slack, abs(other.minX - here.maxX) <= slack,
               !crossesNaturally(other, coordinate: point.y, alongX: true) {
                let y = clamp(point.y, low: other.minY, high: other.maxY - 1)
                offer(CGPoint(x: other.minX, y: y), slide: abs(y - point.y))
            }
            if push.dx < 0, point.x <= here.minX + slack, abs(other.maxX - here.minX) <= slack,
               !crossesNaturally(other, coordinate: point.y, alongX: true) {
                let y = clamp(point.y, low: other.minY, high: other.maxY - 1)
                offer(CGPoint(x: other.maxX - 1, y: y), slide: abs(y - point.y))
            }
            if push.dy > 0, point.y >= here.maxY - slack, abs(other.minY - here.maxY) <= slack,
               !crossesNaturally(other, coordinate: point.x, alongX: false) {
                let x = clamp(point.x, low: other.minX, high: other.maxX - 1)
                offer(CGPoint(x: x, y: other.minY), slide: abs(x - point.x))
            }
            if push.dy < 0, point.y <= here.minY + slack, abs(other.maxY - here.minY) <= slack,
               !crossesNaturally(other, coordinate: point.x, alongX: false) {
                let x = clamp(point.x, low: other.minX, high: other.maxX - 1)
                offer(CGPoint(x: x, y: other.maxY - 1), slide: abs(x - point.x))
            }
        }
        return best?.point
    }

    /// Whether macOS already crosses into `other` at this coordinate, in which
    /// case the pointer is moving of its own accord and must be left alone.
    ///
    /// It does that when the point just past the shared edge is inside the
    /// neighbour: the neighbour is the one display that covers the pointer's own
    /// line, so there is no dead space to escape from.
    private static func crossesNaturally(_ other: CGRect, coordinate: CGFloat, alongX: Bool) -> Bool {
        alongX ? (other.minY <= coordinate && coordinate < other.maxY)
               : (other.minX <= coordinate && coordinate < other.maxX)
    }

    /// The display the pointer is on.
    ///
    /// The pointer is normally inside one, but it can also sit a fraction past an
    /// edge, where macOS has clamped it, or in a dead sliver between displays —
    /// and it is *there* that this feature matters most. So when no display
    /// contains it, the nearest one is treated as the display it came from; the
    /// edge tests against that display decide whether anything happens, so a
    /// pointer far from everything still moves nothing.
    private static func displayUnder(_ point: CGPoint, among displays: [CGRect]) -> CGRect? {
        if let exact = displays.first(where: { $0.contains(point) }) { return exact }
        return displays.min { distance(from: $0, to: point) < distance(from: $1, to: point) }
    }

    private static func distance(from rect: CGRect, to point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return sqrt(dx * dx + dy * dy)
    }

    /// Kept strictly inside the axis, so a landing is always a point the display
    /// actually has. `CGRect.contains` is half-open — a display's `maxX`/`maxY` is
    /// measured to be *not* inside it — so a warp onto the neighbour's boundary
    /// would be a point macOS clamps back onto the display the pointer just left,
    /// and the crossing would appear not to have happened.
    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        guard high > low else { return low }
        return min(max(value, low), high)
    }
}
