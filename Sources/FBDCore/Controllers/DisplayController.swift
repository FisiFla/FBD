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
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "DisplayController")

    private var hasRegistered = false
    private var screenChangeObserver: NSObjectProtocol?
    private var brightnessDebounceWorkItems: [CGDirectDisplayID: DispatchWorkItem] = [:]
    /// Displays we already attempted DDC auto-configuration for, so failed
    /// capability reads are not retried on every reconfiguration event.
    private var autoConfigureAttempted: Set<CGDirectDisplayID> = []

    public init() {
        ddc = DDCController(external: external)
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
    /// Display instances by id, and refresh per-display mode/DDC status.
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
            updated.append(display)
        }
        displays = updated

        // Drop bookkeeping for displays that vanished.
        let liveIDs = Set(ids)
        autoConfigureAttempted = autoConfigureAttempted.intersection(liveIDs)
        let vanished = brightnessDebounceWorkItems.keys.filter { !liveIDs.contains($0) }
        for id in vanished {
            brightnessDebounceWorkItems[id]?.cancel()
            brightnessDebounceWorkItems[id] = nil
        }

        NotificationCenter.default.post(name: .fbdDisplaysChanged, object: nil)
    }

    public func display(withID id: CGDirectDisplayID) -> Display? {
        displays.first { $0.id == id }
    }

    // MARK: - Brightness

    /// Set brightness 0…1, debounced per display via `Settings.brightnessDebounceMilliseconds`.
    /// Routes to AppleController when `display.appleBrightnessAvailable`, else DDC.
    /// Returns true when a control path exists for the display (delivery of the
    /// debounced write is asynchronous; DDC delivery is confirmed by read-back).
    @discardableResult
    public func setBrightness(_ value: Double, on display: Display) -> Bool {
        let clamped = min(max(value, 0), 1)
        guard display.appleBrightnessAvailable || display.ddcAvailable else {
            log.warning("setBrightness: no control path for \(display.id)")
            return false
        }
        let apple = self.apple
        let ddc = self.ddc
        brightnessDebounceWorkItems[display.id]?.cancel()
        let workItem = DispatchWorkItem {
            if display.appleBrightnessAvailable {
                apple.setBrightness(clamped, on: display)
            } else {
                ddc.setFeature(.brightness, value: clamped, for: display)
            }
            display.updateBrightness(clamped)
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
        let value: Double?
        if display.appleBrightnessAvailable {
            value = apple.getBrightness(for: display)
        } else {
            value = ddc.getFeature(.brightness, for: display)
        }
        if let value {
            display.updateBrightness(value)
        }
        return value
    }

    // MARK: - DDC controls

    /// Set contrast 0…1 via DDC/CI. Returns whether the write was accepted.
    @discardableResult
    public func setContrast(_ value: Double, on display: Display) -> Bool {
        ddc.setFeature(.contrast, value: value, for: display)
    }

    /// Set speaker volume 0…1 via DDC/CI. Returns whether the write was accepted.
    @discardableResult
    public func setVolume(_ value: Double, on display: Display) -> Bool {
        ddc.setFeature(.volume, value: value, for: display)
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
    public func applyMode(_ mode: DisplayMode, to display: Display) {
        resolution.applyMode(mode, to: display)
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
    /// Posted after an individual display's mode changed.
    /// userInfo: ["displayID": CGDirectDisplayID].
    static let fbdDisplayUpdated = Notification.Name("FBDDisplayUpdated")
}
