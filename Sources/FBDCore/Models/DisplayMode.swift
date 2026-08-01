import CPrivateAPI
import Foundation

/// A display mode (resolution + refresh rate) as reported by the CGS mode APIs.
public struct DisplayMode: Hashable, Sendable {
    /// CGS mode number (opaque, stable within a display session).
    public let modeNumber: Int32
    /// CGS mode flags: bit 0 = safe, bit 1 = default, bit 0x200000 = HiDPI.
    public let flags: Int32
    public let width: Int32
    public let height: Int32
    /// Physical pixel dimensions (may differ from width/height for scaled modes).
    public let pixelsWide: Int32
    public let pixelsHigh: Int32
    /// Refresh rate in Hz (16.16 fixed point).
    public let refreshRate: Double
    public let encoding: String

    public init(
        modeNumber: Int32,
        flags: Int32,
        width: Int32,
        height: Int32,
        pixelsWide: Int32,
        pixelsHigh: Int32,
        refreshRate: Double,
        encoding: String
    ) {
        self.modeNumber = modeNumber
        self.flags = flags
        self.width = width
        self.height = height
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh
        self.refreshRate = refreshRate
        self.encoding = encoding
    }

    public static let hiDPIFlag: Int32 = 0x200000
    public static let safeFlag: Int32 = 0x1
    public static let defaultFlag: Int32 = 0x2

    public var isHiDPI: Bool { flags & Self.hiDPIFlag != 0 }
    public var isSafe: Bool { flags & Self.safeFlag != 0 }
    public var isDefault: Bool { flags & Self.defaultFlag != 0 }
    public var isRetina: Bool { isHiDPI }

    public var label: String { "\(width) × \(height)" }
    public var refreshLabel: String { refreshRate == 0 ? "" : "\(String(format: "%.2f", refreshRate)) Hz" }

    /// Compact unique-ish key for UI dedup, e.g. "1920x1080@60.00".
    public var key: String { "\(pixelsWide)x\(pixelsHigh)@\(String(format: "%.2f", refreshRate))" }
}

extension DisplayMode {
    /// Mapping from the raw CGS struct (pure — unit-testable).
    public static func from(cgsDescription desc: CGSDisplayModeDescription) -> DisplayMode {
        let encoding = withUnsafeBytes(of: desc.encoding) { raw -> String in
            let bytes = [UInt8](raw)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
        return DisplayMode(
            modeNumber: desc.displayModeNumber,
            flags: desc.flags,
            width: desc.width,
            height: desc.height,
            pixelsWide: desc.pixelsWide,
            pixelsHigh: desc.pixelsHigh,
            refreshRate: Double(desc.fixPtRefreshRate) / 65536.0,
            encoding: encoding
        )
    }
}
