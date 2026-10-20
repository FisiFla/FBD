import Foundation

/// A scaled ("HiDPI") mode: a logical size and the backing store behind it.
///
/// macOS describes a scaled mode by the size of the backing store it draws
/// into; the logical size is what the user sees and what the system reports
/// as the display's resolution. A mode at exactly twice the native size is
/// the "looks like 2×" mode.
public struct HiDPIScaledMode: Equatable, Hashable, Sendable {
    /// The size the user sees, in points.
    public let logicalWidth: Int
    public let logicalHeight: Int

    /// The size of the backing store, in pixels.
    ///
    /// The ladder is a 2× ladder: every logical size is drawn at twice its
    /// size in pixels.
    public var backingWidth: Int { logicalWidth * 2 }
    public var backingHeight: Int { logicalHeight * 2 }

    public init(logicalWidth: Int, logicalHeight: Int) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
    }
}

/// The ladder of scaled modes a display offers.
///
/// The ladder is generated from the display's native resolution: the native
/// size first, then the same aspect ratio at ever smaller logical sizes,
/// until the scale floor or the smallest sensible desktop size is reached.
///
/// The model is pure — no display, no settings, no file system — so every
/// property the ladder has to keep can be tested without hardware.
public enum HiDPILadder {
    /// The step the logical width shrinks by, in points.
    ///
    /// 16 is the grid the scaled-mode overrides use. It keeps the width
    /// aligned to the display's own grid and keeps every logical width a
    /// multiple of 2, so the doubled backing width stays an integer.
    public static let widthStep = 16

    /// The smallest logical width a desktop mode may have, in points.
    public static let minimumLogicalWidth = 800

    /// The smallest logical height a desktop mode may have, in points.
    public static let minimumLogicalHeight = 600

    /// The smallest fraction of the native size the ladder reaches.
    public static let defaultMinimumScale = 0.5

    /// The scaled modes for a native resolution, largest first.
    ///
    /// The native size comes first, then the width shrinks by
    /// `widthStep` points at a time while the height follows the native
    /// aspect ratio. Sizes that would fall below the minimum desktop size,
    /// or below the requested scale floor, are left out.
    ///
    /// - Parameters:
    ///   - nativeWidth: the native width in pixels.
    ///   - nativeHeight: the native height in pixels.
    ///   - minimumScale: the smallest fraction of the native size to reach.
    public static func logicalSizes(
        nativeWidth: Int,
        nativeHeight: Int,
        minimumScale: Double = defaultMinimumScale
    ) -> [HiDPIScaledMode] {
        guard nativeWidth > 0, nativeHeight > 0 else { return [] }
        let scale = minimumScale.isFinite ? min(max(minimumScale, 0.1), 1) : defaultMinimumScale

        // The width the ladder must not go below: the scale floor, the
        // smallest desktop width, and the width at which the height would
        // fall under the minimum desktop height.
        let scaleFloor = Int((Double(nativeWidth) * scale).rounded(.up))
        let heightFloor = Int((Double(minimumLogicalHeight) * Double(nativeWidth) / Double(nativeHeight)).rounded(.up))
        let floorWidth = max(scaleFloor, minimumLogicalWidth, heightFloor)

        var modes: [HiDPIScaledMode] = []
        var width = nativeWidth
        while width >= floorWidth {
            let height = Int((Double(width) * Double(nativeHeight) / Double(nativeWidth)).rounded())
            guard height >= minimumLogicalHeight else { break }
            modes.append(HiDPIScaledMode(logicalWidth: width, logicalHeight: height))
            width -= widthStep
        }
        return modes
    }

    /// The `scale-resolutions` entries for a ladder.
    ///
    /// Each entry is the backing size of one mode, as four big-endian bytes
    /// of width followed by four big-endian bytes of height — the format the
    /// macOS display overrides use.
    public static func scaleResolutions(_ modes: [HiDPIScaledMode]) -> [Data] {
        modes.map(encode)
    }

    /// The eight-byte `scale-resolutions` entry for one mode.
    public static func encode(_ mode: HiDPIScaledMode) -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        let width = UInt32(max(mode.backingWidth, 0))
        let height = UInt32(max(mode.backingHeight, 0))
        bytes[0] = UInt8((width >> 24) & 0xFF)
        bytes[1] = UInt8((width >> 16) & 0xFF)
        bytes[2] = UInt8((width >> 8) & 0xFF)
        bytes[3] = UInt8(width & 0xFF)
        bytes[4] = UInt8((height >> 24) & 0xFF)
        bytes[5] = UInt8((height >> 16) & 0xFF)
        bytes[6] = UInt8((height >> 8) & 0xFF)
        bytes[7] = UInt8(height & 0xFF)
        return Data(bytes)
    }
}
