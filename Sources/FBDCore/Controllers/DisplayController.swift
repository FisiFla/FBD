import AppKit
import CoreGraphics
import Foundation
import IOKit
import os

/// Owns the display list and routes brightness/DDC operations to the dedicated
/// controllers. The single @MainActor surface the UI talks to.
@MainActor
public final class DisplayController {
    public static let shared = DisplayController()

    /// Live display list, in CGGetActiveDisplayList order. Display instances
    /// are preserved across refreshes by id (reference identity matters —
    /// SwiftUI observes them).
    public private(set) var displays: [Display] = []

    private let apple = AppleController()
    private let external = ExternalController()
    private let ddc: DDCController
    private let resolution = ResolutionController()
    private let xdr = XDRNativeController()
    private let overlay = OverlayController()
    private let brightnessObserver = BrightnessChangeObserver()
    private let combined: CombinedController
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "DisplayController")

    private var hasRegistered = false
    private var screenChangeObserver: NSObjectProtocol?
    private var brightnessDebounceWorkItems: [CGDirectDisplayID: DispatchWorkItem] = [:]
    /// Displays we already attempted DDC auto-configuration for, so failed
    /// capability reads are not retried on every reconfiguration event.
    private var autoConfigureAttempted: Set<CGDirectDisplayID> = []

    public init() {
        ddc = DDCController(external: external)
        combined = CombinedController(apple: apple, ddc: ddc, xdr: xdr, overlay: overlay)
    }

    // MARK: - DDC surface (typed, no controller exposure)

    /// DDC controls for a display (contrast/volume/mute/input). Each value is
    /// nil when the display has no AVService or the feature read failed.
    public struct DDCControls: Equatable {
        public let contrast: Double?
        public let volume: Double?
        public let muted: Bool?
        public let inputSource: Double?
    }

    /// Read the DDC controls for a display through the shared DDC controller
    /// (single AVService cache, per-display serial queue and cooldown).
    public func readDDCControls(for display: Display) -> DDCControls {
        DDCControls(
            contrast: ddc.getFeature(.contrast, for: display),
            volume: ddc.getFeature(.volume, for: display),
            muted: ddc.getFeature(.mute, for: display).map { $0 > 0 },
            inputSource: ddc.getFeature(.inputSource, for: display)
        )
    }

    /// Read + parse the display's DDC capabilities reply (nil when DDC is
    /// unavailable or the reply could not be parsed).
    public func readDDCCapabilities(for display: Display) -> DDC.DDCCapabilities? {
        ddc.readCapabilities(for: display)
    }

    /// Whether a DDC feature is supported by the display (persisted feature
    /// set, falling back to one live capabilities read per display).
    public func isDDCFeatureAvailable(_ feature: DDCFeature, for display: Display) -> Bool {
        ddc.isFeatureAvailable(feature, for: display)
    }

    // MARK: - Lifecycle

    /// Register display-change observation and perform the initial refresh.
    public func start() {
        guard !hasRegistered else { return }
        hasRegistered = true

        // The reconfiguration callback arrives on a background thread — hop to main.
        let registered = CGDisplayRegisterReconfigurationCallback({ _, _, _ in
            Task { @MainActor in
                DisplayController.shared.refresh()
            }
        }, nil)
        if registered != .success {
            log.warning("CGDisplayRegisterReconfigurationCallback failed: \(registered.rawValue)")
        }

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        refresh()
    }

    /// Re-enumerate displays with CGGetActiveDisplayList, preserving existing
    /// Display instances by id, and refresh per-display mode/DDC/XDR status,
    /// plus hardware brightness-change observation.
    public func refresh() {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            log.error("CGGetActiveDisplayList failed")
            return
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard ids.withUnsafeMutableBufferPointer({
            CGGetActiveDisplayList(UInt32($0.count), $0.baseAddress, &count)
        }) == .success else {
            log.error("CGGetActiveDisplayList (fill) failed")
            return
        }
        ids = Array(ids.prefix(Int(count)))

        var byID: [CGDirectDisplayID: Display] = [:]
        for display in displays { byID[display.id] = display }

        var updated: [Display] = []
        for id in ids {
            let display = byID[id] ?? makeDisplay(id: id)
            populate(display, id: id)
            xdr.refresh(for: display)
            if display.appleBrightnessAvailable {
                brightnessObserver.observe(display: display)
                // Initial read so the UI shows the current value at launch —
                // the observer only fires on external brightness *changes*.
                _ = getBrightness(for: display)
            }
            updated.append(display)
        }
        displays = updated

        // Drop bookkeeping for displays that vanished.
        let liveIDs = Set(ids)
        VirtualDisplayRegistry.shared.prune(keeping: liveIDs)
        autoConfigureAttempted = autoConfigureAttempted.intersection(liveIDs)
        let vanished = brightnessDebounceWorkItems.keys.filter { !liveIDs.contains($0) }
        for id in vanished {
            brightnessDebounceWorkItems[id]?.cancel()
            brightnessDebounceWorkItems[id] = nil
            brightnessObserver.unobserve(displayID: id)
        }

        NotificationCenter.default.post(name: .fbdDisplaysChanged, object: nil)
    }

    public func display(withID id: CGDirectDisplayID) -> Display? {
        displays.first { $0.id == id }
    }

    // MARK: - Brightness

    /// Set brightness 0…1, debounced per display via `Settings.brightnessDebounceMilliseconds`.
    /// Routes through CombinedController: Tier 1 (Apple when
    /// `display.appleBrightnessAvailable`, else DDC) unless combined mode is
    /// on, which extends the curve with XDR upscaling / software boost.
    /// Returns true when a control path exists for the display (delivery of the
    /// debounced write is asynchronous; DDC delivery is confirmed by read-back).
    @discardableResult
    public func setBrightness(_ value: Double, on display: Display) -> Bool {
        let clamped = min(max(value, 0), 1)
        guard display.appleBrightnessAvailable || display.ddcAvailable else {
            log.warning("setBrightness: no control path for \(display.id)")
            return false
        }
        let combined = self.combined
        brightnessDebounceWorkItems[display.id]?.cancel()
        let workItem = DispatchWorkItem {
            combined.setBrightness(clamped, on: display)
            display.updateBrightness(clamped)
            // Let the OSD and any observers follow UI/CLI brightness writes.
            NotificationCenter.default.post(name: .fbdDisplayUpdated, object: nil, userInfo: ["displayID": display.id])
        }
        brightnessDebounceWorkItems[display.id] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Settings.brightnessDebounceMilliseconds),
            execute: workItem
        )
        return true
    }

    /// Current brightness 0…1 and updates `display.brightness`.
    public func getBrightness(for display: Display) -> Double? {
        let value = combined.getBrightness(for: display)
        if let value {
            display.updateBrightness(value)
        }
        return value
    }

    // MARK: - XDR, HDR, overlays (passthroughs)

    /// Raise the native XDR upscale target (nits) for the display.
    @discardableResult
    public func setXDRUpscaleTarget(_ nits: Int, on display: Display) -> Bool {
        switch XDRBoostPlanner.plan(
            nits: nits,
            hardwareMaxNits: combined.hardwareMaxNits(for: display),
            nativeAvailable: xdr.isAvailable(for: display),
            softwareEnabled: Settings.softwareUpscalingEnabled
        ) {
        case .nativeUpscale(let target):
            if xdr.setUpscaleTarget(target, for: display) {
                return true
            }
            // Native preset write failed (e.g. write-protected preset slots
            // on macOS 27). Fall back to the software boost overlay when it
            // is enabled and the target has headroom above the hardware
            // ceiling — otherwise the explicit `xdr <id> <nits>` command is
            // dead on write-protected systems.
            let hardwareMax = combined.hardwareMaxNits(for: display)
            guard Settings.softwareUpscalingEnabled, hardwareMax > 0, target > hardwareMax else {
                return false
            }
            let ok = overlay.setSoftwareBoost(Double(target) / Double(hardwareMax), displayID: display.id)
            if ok {
                display.updateSoftwareBoost(true, targetNits: target)
            }
            return ok
        case .softwareBoost(let factor):
            // Requires Screen Recording permission (logged by the overlay).
            let ok = overlay.setSoftwareBoost(factor, displayID: display.id)
            if ok {
                display.updateSoftwareBoost(true, targetNits: nits)
            }
            return ok
        case .hardware, .fail:
            return false
        }
    }

    /// Display IDs currently running a software boost overlay.
    public func activeBoostDisplayIDs() -> [UInt32] {
        overlay.activeBoostDisplayIDs()
    }

    // MARK: - Full-screen image adjustments

    /// Apply (or update) the full-screen software filter for a display.
    /// Neutral params stop it.
    @discardableResult
    public func setScreenFilter(_ params: ScreenFilterParams, on display: Display) -> Bool {
        overlay.setScreenFilter(params, displayID: display.id)
    }

    /// Stop the full-screen filter for a display.
    public func stopScreenFilter(on display: Display) {
        overlay.stopScreenFilter(displayID: display.id)
    }

    // MARK: - Ambient light compensation (Auto Brightness)

    /// Whether the display's ambient-light compensation ("auto brightness")
    /// is on. Nil when the display does not support it.
    public func isAmbientLightCompensationEnabled(on display: Display) -> Bool? {
        apple.isAmbientLightCompensationEnabled(for: display)
    }

    public func setAmbientLightCompensation(_ enabled: Bool, on display: Display) {
        apple.setAmbientLightCompensation(enabled, for: display)
    }

    /// Rotate the display (degrees: 0/90/180/270). Returns the applied
    /// rotation on success, nil on failure.
    @discardableResult
    public func setRotation(_ degrees: Int, on display: Display) -> Int? {
        SkyLightAPI.setRotation(degrees, for: display.id)
    }

    // MARK: - Main display / arrangement

    /// Make the display the main (menu-bar) display by moving its origin to
    /// (0, 0) — the arrangement macOS treats as primary. Same mechanism as
    /// LayoutProtectionController.restoreArrangement.
    @discardableResult
    public func setAsMainDisplay(_ display: Display) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config,
              CGConfigureDisplayOrigin(config, display.id, 0, 0) == .success else {
            return false
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    /// Remove native XDR upscaling (restore the factory preset) and stop any
    /// software boost overlay.
    @discardableResult
    public func disableXDRUpscaling(on display: Display) -> Bool {
        let native = xdr.disableUpscaling(for: display)
        overlay.setSoftwareBoost(1, displayID: display.id)
        display.updateSoftwareBoost(false, targetNits: nil)
        return native
    }

    /// Activate a display preset by index.
    @discardableResult
    public func selectPreset(_ index: Int, on display: Display) -> Bool {
        xdr.selectPreset(index, for: display)
    }

    /// Force the HDR framebuffer mode (external HDR displays only).
    @discardableResult
    public func setHDRMode(_ enabled: Bool, on display: Display) -> Bool {
        xdr.setHDRMode(enabled, for: display)
    }

    /// Start (or update) the software brightness-boost overlay for a display;
    /// factor <= 1 stops the stream.
    @discardableResult
    public func setSoftwareBoost(_ factor: Double, on display: Display) -> Bool {
        let ok = overlay.setSoftwareBoost(factor, displayID: display.id)
        display.updateSoftwareBoost(factor > 1 && ok, targetNits: nil)
        return ok
    }

    /// Set the dim-to-black overlay opacity 0…1 (0 = none, 1 = fully black).
    public func setDimFactor(_ factor: Double, on display: Display) {
        overlay.setDimFactor(factor, displayID: display.id)
    }

    /// Dim-to-black on/off (fully black vs. no dimming).
    public func setDimToBlack(_ enabled: Bool, on display: Display) {
        combined.setDimToBlack(enabled, on: display)
    }

    // MARK: - DDC controls

    /// Read contrast 0…1 via DDC/CI, or nil when the monitor doesn't answer.
    public func readContrast(for display: Display) -> Double? {
        ddc.getFeature(.contrast, for: display)
    }

    /// Set contrast 0…1 via DDC/CI. Returns whether the write was accepted.
    @discardableResult
    public func setContrast(_ value: Double, on display: Display) -> Bool {
        ddc.setFeature(.contrast, value: value, for: display)
    }

    /// Read speaker volume 0…1 via DDC/CI, or nil when the monitor doesn't answer.
    public func readVolume(for display: Display) -> Double? {
        ddc.getFeature(.volume, for: display)
    }

    /// Set speaker volume 0…1 via DDC/CI. Returns whether the write was accepted.
    @discardableResult
    public func setVolume(_ value: Double, on display: Display) -> Bool {
        ddc.setFeature(.volume, value: value, for: display)
    }

    /// Read the speaker mute state via DDC/CI (MCCS 0x8D: 1 = on, 2 = off),
    /// or nil when the monitor doesn't answer.
    public func readMuted(for display: Display) -> Bool? {
        guard let raw = ddc.getFeature(.mute, for: display) else { return nil }
        return raw <= 1.5
    }

    /// Mute/unmute the display's speakers via DDC/CI. Returns whether the write was accepted.
    @discardableResult
    public func setMuted(_ muted: Bool, on display: Display) -> Bool {
        // MCCS 0x8D: 1 = mute on, 2 = mute off.
        ddc.setFeature(.mute, value: muted ? 1 : 2, for: display)
    }

    /// Switch the display's input source (VCP 0x60 value) via DDC/CI.
    /// Returns whether the write was accepted.
    @discardableResult
    public func setInputSource(_ source: UInt16, on display: Display) -> Bool {
        ddc.setFeature(.inputSource, value: Double(source), for: display)
    }

    /// Read and cache the display's DDC capabilities (also updates its status).
    public func readCapabilities(for display: Display) {
        guard let caps = ddc.readCapabilities(for: display) else {
            log.warning("readCapabilities failed for \(display.id)")
            return
        }
        display.updateDDCStatus(available: true, capabilities: caps)
    }

    // MARK: - Modes

    /// Apply a resolution/refresh-rate mode.
    @discardableResult
    public func applyMode(_ mode: DisplayMode, to display: Display) -> Bool {
        return resolution.applyMode(mode, to: display)
    }

    // MARK: - Environment

    /// Whether the process runs under Rosetta 2 (DDC is unavailable then).
    public var isRunningUnderRosetta: Bool {
        IOAVServiceAPI.isRunningUnderRosetta
    }

    // MARK: - Display construction

    private func makeDisplay(id: CGDirectDisplayID) -> Display {
        Display(
            id: id,
            name: displayName(for: id) ?? "Display \(id)",
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            vendorNumber: CGDisplayVendorNumber(id),
            modelNumber: CGDisplayModelNumber(id),
            serialNumber: CGDisplaySerialNumber(id),
            bounds: CGDisplayBounds(id),
            isOnline: CGDisplayIsOnline(id) != 0,
            isActive: CGDisplayIsActive(id) != 0
        )
    }

    private func populate(_ display: Display, id: CGDirectDisplayID) {
        display.updateSnapshot(
            name: displayName(for: id),
            bounds: CGDisplayBounds(id),
            isOnline: CGDisplayIsOnline(id) != 0,
            isActive: CGDisplayIsActive(id) != 0
        )
        display.updateModes(resolution.modes(for: display), current: resolution.currentMode(for: display))
        display.updateAppleBrightnessStatus(available: apple.isAvailable(for: display))
        refreshDDCStatus(for: display)
    }

    /// DDC availability + persisted capabilities. On first connect, when
    /// `Settings.ddcAutoConfigure` is on, auto-configure from a live
    /// capabilities read (once per display).
    private func refreshDDCStatus(for display: Display) {
        guard ddc.isAvailable(for: display) else {
            display.updateDDCStatus(available: false, capabilities: nil)
            return
        }
        let features = Settings.ddcFeatures(for: display.identityKey)
        if features.isEmpty, Settings.ddcAutoConfigure, !autoConfigureAttempted.contains(display.id) {
            autoConfigureAttempted.insert(display.id)
            ddc.autoConfigure(for: display)
            return
        }
        display.updateDDCStatus(available: true, capabilities: display.ddcCapabilities)
    }

    /// Preferred display name via the public AppKit API (NSScreen.localizedName),
    /// which matches the name shown in System Settings.
    private func displayName(for id: CGDirectDisplayID) -> String? {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }),
              !screen.localizedName.isEmpty else {
            return nil
        }
        return screen.localizedName
    }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted after a full display enumeration (displays added/removed/changed).
    /// No userInfo.
    static let fbdDisplaysChanged = Notification.Name("FBDDisplaysChanged")
    /// Posted when global media-key interception is unavailable (permission
    /// missing/revoked or the event tap failed to enable).
    static let fbdHotkeysUnavailable = Notification.Name("FBDHotkeysUnavailable")
    /// Posted after an individual display's mode changed.
    /// userInfo: ["displayID": CGDirectDisplayID].
    static let fbdDisplayUpdated = Notification.Name("FBDDisplayUpdated")
}
