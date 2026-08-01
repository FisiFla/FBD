import CoreGraphics
import Foundation

/// Persisted configuration of a virtual screen (macOS 26+: SLVirtualDisplay;
/// macOS 13–15: CGVirtualDisplay).
public struct VirtualScreenConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String          // stable UUID
    public var name: String
    public var width: UInt32
    public var height: UInt32
    public var refreshRate: Double
    public var isHDR: Bool
    /// When true, reconnect automatically after wake (or on app start).
    public var autoConnect: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        width: UInt32,
        height: UInt32,
        refreshRate: Double = 60,
        isHDR: Bool = false,
        autoConnect: Bool = true
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.isHDR = isHDR
        self.autoConnect = autoConnect
    }

    public var pixelSize: (width: UInt32, height: UInt32) { (width, height) }
}

/// A user-defined group of displays for synced control.
public final class DisplayGroup: ObservableObject, Identifiable {
    public let id: String
    @Published public var name: String
    @Published public var displayIDs: Set<CGDirectDisplayID>

    public init(id: String = UUID().uuidString, name: String, displayIDs: Set<CGDirectDisplayID> = []) {
        self.id = id
        self.name = name
        self.displayIDs = displayIDs
    }
}

/// Saved display arrangement (layout protection): display id → origin.
public struct LayoutAnchor: Codable, Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let x: Int32
    public let y: Int32

    public init(displayID: CGDirectDisplayID, x: Int32, y: Int32) {
        self.displayID = displayID
        self.x = x
        self.y = y
    }
}
