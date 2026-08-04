import CoreGraphics
import Foundation

/// Pure arrangement geometry for the drag-to-arrange grid.
/// Split from the SwiftUI view so the snapping logic is unit-testable.
public enum ArrangementMath {
    /// Adjusts a dragged display's origin so its edges align to a peer's
    /// edges (System Settings-style snapping). Each axis snaps independently:
    /// the X axis aligns this frame's left/right edge to the nearest peer
    /// left/right edge within `threshold`, and the Y axis does the same for
    /// top/bottom. This keeps an already-x-aligned drag free to snap on Y.
    public static func snappedOrigin(
        for frame: CGRect,
        peers: [CGRect],
        threshold: CGFloat
    ) -> CGPoint {
        var origin = frame.origin
        var bestDx: CGFloat?
        var bestDy: CGFloat?

        for peer in peers {
            for dx in [peer.minX - frame.minX, peer.maxX - frame.maxX] where abs(dx) <= threshold {
                if bestDx == nil || abs(dx) < abs(bestDx!) {
                    bestDx = dx
                }
            }
            for dy in [peer.minY - frame.minY, peer.maxY - frame.maxY] where abs(dy) <= threshold {
                if bestDy == nil || abs(dy) < abs(bestDy!) {
                    bestDy = dy
                }
            }
        }

        origin.x += bestDx ?? 0
        origin.y += bestDy ?? 0
        return origin
    }
}
