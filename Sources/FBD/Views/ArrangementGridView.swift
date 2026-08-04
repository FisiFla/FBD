import AppKit
import CoreGraphics
import FBDCore
import SwiftUI

/// System Settings-style display arrangement grid: each display is a tile
/// positioned by its real desktop bounds; drag a tile to move the display.
/// Commits through the public CoreGraphics configuration API
/// (`DisplayController.setOrigin`).
@MainActor
struct ArrangementGridView: View {
    /// Canvas size in points (the grid scales the desktop into this box).
    private let canvasSize = CGSize(width: 340, height: 180)
    @State private var draggingID: CGDirectDisplayID?
    /// Re-render when the display set changes (the grid reads
    /// DisplayController.shared directly — it is not an ObservableObject).
    @State private var refreshTick = 0

    private var displays: [Display] {
        DisplayController.shared.displays.filter(\.isOnline)
    }

    private var fit: (scale: CGFloat, offset: CGPoint, bbox: CGRect)? {
        guard !displays.isEmpty else { return nil }
        let bbox = displays.reduce(CGRect.null) { $0.union($1.bounds) }
        guard !bbox.isNull, bbox.width > 0, bbox.height > 0 else { return nil }
        let scale = min(canvasSize.width / bbox.width, canvasSize.height / bbox.height, 1)
        let offset = CGPoint(
            x: (canvasSize.width - bbox.width * scale) / 2 - bbox.minX * scale,
            y: (canvasSize.height - bbox.height * scale) / 2 - bbox.minY * scale
        )
        return (scale, offset, bbox)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: FBDTheme.radiusInset, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))
            if let fit {
                ForEach(displays) { display in
                    tile(for: display, fit: fit)
                }
            } else {
                Text("No displays connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipShape(RoundedRectangle(cornerRadius: FBDTheme.radiusInset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FBDTheme.radiusInset, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onReceive(NotificationCenter.default.publisher(for: .fbdDisplaysChanged)) { _ in
            refreshTick += 1
        }
        .id(refreshTick)
    }

    private func tile(for display: Display, fit: (scale: CGFloat, offset: CGPoint, bbox: CGRect)) -> some View {
        let rect = CGRect(
            x: fit.offset.x + display.bounds.minX * fit.scale,
            y: fit.offset.y + display.bounds.minY * fit.scale,
            width: display.bounds.width * fit.scale,
            height: display.bounds.height * fit.scale
        )
        let isMain = display.id == CGMainDisplayID()
        let isDragging = draggingID == display.id

        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isDragging ? Color.accentColor.opacity(0.85) : (isMain ? Color.accentColor.opacity(0.25) : Color.accentColor.opacity(0.55)))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
            )
            .overlay(
                Text(display.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(3)
                    .frame(maxWidth: .infinity, alignment: .leading),
                alignment: .bottomLeading
            )
            .frame(width: max(rect.width, 24), height: max(rect.height, 14))
            .position(x: rect.midX, y: rect.midY)
            .shadow(color: .black.opacity(isDragging ? 0.4 : 0.2), radius: isDragging ? 6 : 3)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in draggingID = display.id }
                    .onEnded { value in
                        defer { draggingID = nil }
                        commitMove(display, translation: value.translation, fit: fit)
                    }
            )
    }

    /// Converts the drag translation into a snapped absolute origin and
    /// commits it. Snapping aligns the dragged display's edges to the other
    /// displays' edges (within a 24-pt threshold on the canvas) so tiles
    /// land edge-aligned like System Settings.
    private func commitMove(_ display: Display, translation: CGSize, fit: (scale: CGFloat, offset: CGPoint, bbox: CGRect)) {
        let currentOrigin = display.bounds.origin
        let delta = CGPoint(x: translation.width / fit.scale, y: translation.height / fit.scale)
        var newOrigin = CGPoint(x: currentOrigin.x + delta.x, y: currentOrigin.y + delta.y)

        // Snap: prefer aligning this display's edges to a peer's edges
        // (threshold in canvas points, converted to desktop points).
        let frame = CGRect(origin: newOrigin, size: display.bounds.size)
        let threshold = 24 * 2 / fit.scale
        let peers = displays.filter { $0.id != display.id }.map(\.bounds)
        let snapped = ArrangementMath.snappedOrigin(for: frame, peers: peers, threshold: threshold)
        newOrigin = snapped

        let ok = DisplayController.shared.setOrigin(newOrigin, for: display)
        if !ok {
            NSSound.beep()
        }
    }
}
