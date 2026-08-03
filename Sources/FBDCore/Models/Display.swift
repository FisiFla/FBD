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

    // MARK: XDR state (set by XDRNativeController)

    /// Display presets (Apple displays only; empty for non-Apple displays).
    @Published public private(set) var presets: [XDRPreset] = []
    /// Whether the display has Apple preset support (XDR-capable).
    @Published public private(set) var isXDRCapable: Bool = false
    /// Currently active preset index (nil = factory default).
    @Published public private(set) var activePresetIndex: Int?
    /// True while native XDR upscaling is applied.
    @Published public private(set) var isXDRUpscaled: Bool = false
    /// Target nits of the active upscaling, when applied.
    @Published public private(set) var xdrUpscaleTargetNits: Int?
    /// Whether the display supports the HDR framebuffer mode.
    @Published public private(set) var isHDRModeCapable: Bool = false
    @Published public private(set) var isHDRModeEnabled: Bool = false

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

    /// Reflect software-boost overlay state (the overlay itself has no
    /// Display reference). Keeps `isXDRUpscaled`/`xdrUpscaleTargetNits`
    /// honest for the UI, the HTTP API and the CLI regardless of which
    /// mechanism (native preset or software overlay) is boosting.
    public func updateSoftwareBoost(_ active: Bool, targetNits: Int?) {
        isXDRUpscaled = active
        xdrUpscaleTargetNits = active ? targetNits : nil
    }

    public func updateModes(_ modes: [DisplayMode], current: DisplayMode?) {
        self.modes = modes
        currentMode = current
    }

    public func updateDDCStatus(available: Bool, capabilities: DDC.DDCCapabilities?) {
        ddcAvailable = available
        ddcCapabilities = capabilities
    }

    public func updateXDRState(
        presets: [XDRPreset],
        isXDRCapable: Bool,
        activePresetIndex: Int?,
        isXDRUpscaled: Bool,
        xdrUpscaleTargetNits: Int?,
        isHDRModeCapable: Bool,
        isHDRModeEnabled: Bool
    ) {
        self.presets = presets
        self.isXDRCapable = isXDRCapable
        self.activePresetIndex = activePresetIndex
        self.isXDRUpscaled = isXDRUpscaled
        self.xdrUpscaleTargetNits = xdrUpscaleTargetNits
        self.isHDRModeCapable = isHDRModeCapable
        self.isHDRModeEnabled = isHDRModeEnabled
    }

    public func updateAppleBrightnessStatus(available: Bool) {
        appleBrightnessAvailable = available
    }

    /// True for displays FBD created as virtual screens (authoritative
    /// registry) or displays matching the legacy magic-ID fingerprints
    /// (Sidecar/AirPlay/other tools: 0xF0F0 / 0x896 / vendor 0x0100+model 0).
    public var isVirtual: Bool {
        VirtualDisplayRegistry.shared.contains(id)
            || id == 0xF0F0 || id == 0x896
            || (vendorNumber == 0x0100 && modelNumber == 0x0000)
    }

    /// Stable identity used for per-display persisted settings (DDC features, brightness).
    public var identityKey: String { "\(vendorNumber)-\(modelNumber)-\(serialNumber)" }
}

extension Display: Hashable {
    public static func == (lhs: Display, rhs: Display) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
