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
        guard let value else {
            brightness = nil
            return
        }
        // While the below-floor blend is in force the hardware is pinned at the
        // panel's floor, so anything that reports the hardware — a read-back
        // or a hardware-change notification — reports that floor rather than
        // the position the user asked for. The model keeps the logical
        // position the blend carries: a notification that the hardware moved
        // must not drag the slider back to the floor.
        if floorBlendFactor < 1 {
            brightness = floorBlendPosition
            return
        }
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

    /// The software dim in force, 1 = undimmed (0 = fully dimmed).
    ///
    /// Tracked per display because the brightness route owns it: `hardwareBrightness` alone is
    /// not what the screen shows once a dim is applied, and a read that disagrees with the
    /// screen is the bug this area kept repeating. The lock/dim-to-black overlay is a
    /// *different* source and does not write this.
    public private(set) var softwareDim: Double = 1

    /// Record the software dim this display is at. Clamped, and no-op-safe.
    public func updateSoftwareDim(_ factor: Double) {
        softwareDim = min(max(factor, 0), 1)
    }

    /// The multiplicative factor the below-floor brightness blend is applying,
    /// 1 = no blend in force.
    ///
    /// Tracked for the same reason the software dim is: while the blend pins
    /// the hardware at the panel's floor, the hardware read-back reports that
    /// floor rather than the position the user asked for. The factor is the
    /// part that carries the difference, so a read has to take it into
    /// account — see `BrightnessFloorBlend.reconstructSlider`.
    public private(set) var floorBlendFactor: Double = 1

    /// The logical slider position the blend carries, 0 when no blend is in
    /// force.
    ///
    /// The blend knows what the user asked for; the hardware does not (it is
    /// pinned at the panel's floor). This is that position, so the model can
    /// keep reporting it when the hardware says something else.
    public private(set) var floorBlendPosition: Double = 0

    /// Record the below-floor blend factor this display is at, with the
    /// logical position the factor carries. Clamped.
    ///
    /// The position is only meaningful while the factor is below 1 — that is
    /// what "the blend is in force" means.
    public func updateFloorBlendFactor(_ factor: Double, position: Double = 0) {
        floorBlendFactor = min(max(factor, 0), 1)
        floorBlendPosition = min(max(position, 0), 1)
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
    ///
    /// The method is a stored preference (`Settings.displayIdentityMethod`); its
    /// default reproduces the historical `vendor-model-serial` string exactly, so
    /// an existing install keeps every per-display setting attached. Changing it
    /// re-keys them, which is what `DisplaySettingsTransfer` is for.
    public var identityKey: String {
        DisplayIdentity.key(
            vendor: vendorNumber,
            model: modelNumber,
            serial: serialNumber,
            name: name,
            method: Settings.displayIdentityMethod
        )
    }

    /// The panel's physical size in millimetres, or nil when it does not report one.
    ///
    /// Read straight from `CGDisplayScreenSize` rather than cached from a refresh:
    /// it is a property of the panel, not of the session, and a stale copy would be a
    /// second thing to keep in step. Nil — rather than a zero size — for a panel whose
    /// EDID carries no dimensions, because a zero would make every points-per-mm
    /// calculation infinite and then match everything to it.
    public var physicalSizeMM: CGSize? {
        let size = CGDisplayScreenSize(id)
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            return nil
        }
        return size
    }

    /// This display's current GUI scale: logical points per millimetre of panel.
    ///
    /// Nil when the panel size is unknown or the current mode is. See
    /// `UIScaleMatching` for what the number is used for.
    public var guiScale: Double? {
        guard let physical = physicalSizeMM, let mode = currentMode else { return nil }
        return UIScaleMatching.scale(
            logicalWidth: Double(mode.width),
            physicalWidthMM: Double(physical.width)
        )
    }

    /// The modes to offer for this display: the raw list filtered by the stored
    /// mode-list options.
    ///
    /// Everything that *lists* modes goes through this, so "Allow unsafe modes"
    /// actually changes what is offered — before this, the filter existed, the setting
    /// existed, and nothing joined them. The pickers that resolve an explicit request
    /// (`setRefreshRate`, `applyFavourite`) still work from `modes`: they answer a
    /// specific ask rather than presenting a choice to pick from.
    public var offeredModes: [DisplayMode] {
        ModeFavourites.filter(modes, options: .fromSettings, nativeAspect: nil)
    }
}

extension Display: Hashable {
    public static func == (lhs: Display, rhs: Display) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
