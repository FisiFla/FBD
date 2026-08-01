import Combine
import CoreGraphics
import Foundation

/// A display known to macOS. Reference type so SwiftUI menus can observe it.
public final class Display: ObservableObject, Identifiable {
    public let id: CGDirectDisplayID
    public let isBuiltin: Bool

    @Published public private(set) var name: String
    @Published public private(set) var vendorNumber: UInt32
    @Published public private(set) var modelNumber: UInt32
    @Published public private(set) var serialNumber: UInt32
    @Published public private(set) var bounds: CGRect
    @Published public private(set) var isOnline: Bool
    @Published public private(set) var isActive: Bool
    @Published public private(set) var modes: [DisplayMode] = []
    @Published public private(set) var currentMode: DisplayMode?
    /// Last known 0…1 brightness (user-visible value; source depends on controller).
    @Published public private(set) var brightness: Double?
    /// Whether a DDC/CI control path was detected for this display.
    @Published public private(set) var ddcAvailable: Bool = false
    /// Whether Apple's brightness path (DisplayServices) is available.
    @Published public private(set) var appleBrightnessAvailable: Bool = false

    /// Cached DDC capabilities (parsed VCP feature list), set by DDCController.
    @Published public var ddcCapabilities: DDC.DDCCapabilities?

    public init(
        id: CGDirectDisplayID,
        name: String,
        isBuiltin: Bool,
        vendorNumber: UInt32,
        modelNumber: UInt32,
        serialNumber: UInt32,
        bounds: CGRect,
        isOnline: Bool,
        isActive: Bool
    ) {
        self.id = id
        self.name = name
        self.isBuiltin = isBuiltin
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.bounds = bounds
        self.isOnline = isOnline
        self.isActive = isActive
    }

    public func updateSnapshot(
        name: String? = nil,
        bounds: CGRect? = nil,
        isOnline: Bool? = nil,
        isActive: Bool? = nil
    ) {
        if let name { self.name = name }
        if let bounds { self.bounds = bounds }
        if let isOnline { self.isOnline = isOnline }
        if let isActive { self.isActive = isActive }
    }

    public func updateBrightness(_ value: Double?) {
        brightness = value
    }

    public func updateModes(_ modes: [DisplayMode], current: DisplayMode?) {
        self.modes = modes
        currentMode = current
    }

    public func updateDDCStatus(available: Bool, capabilities: DDC.DDCCapabilities?) {
        ddcAvailable = available
        ddcCapabilities = capabilities
    }

    public func updateAppleBrightnessStatus(available: Bool) {
        appleBrightnessAvailable = available
    }

    public var isVirtual: Bool { id == 0xF0F0 || id == 0x896 || vendorNumber == 0x0100 && modelNumber == 0x0000 }

    /// Stable identity used for per-display persisted settings (DDC features, brightness).
    public var identityKey: String { "\(vendorNumber)-\(modelNumber)-\(serialNumber)" }
}

extension Display: Hashable {
    public static func == (lhs: Display, rhs: Display) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
