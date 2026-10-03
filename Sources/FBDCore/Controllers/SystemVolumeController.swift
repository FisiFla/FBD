import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "SystemVolumeController")

/// The Mac's own output volume, over the CoreAudio HAL (#20).
///
/// FBD could previously change volume only over DDC (monitor speakers) or a
/// network TV/AVR — never the Mac's own output, which is what the media keys
/// normally drive. This is the **one** path for that: the CLI, the OSD and any
/// UI go through it rather than each holding its own device handle.
///
/// **HAL calls never run on the caller's thread.** A synchronous property read
/// or write is a round trip to coreaudiod *and* to the device, which on a slow
/// USB interface takes hundreds of milliseconds; doing that inline would stall
/// the UI.
///
/// **Not every output device can be controlled.** An HDMI output — a TV's
/// speakers, say — exposes no software volume at all, and neither do some USB
/// interfaces. FBD says so rather than moving a HUD for a write that would be
/// dropped, which is why `targetHasVolumeControl` exists and why `set` refuses
/// instead of pretending.
@MainActor
public final class SystemVolumeController {
    /// An output device FBD can offer to control.
    public struct OutputDevice: Equatable, Identifiable {
        public let id: AudioDeviceID
        public let name: String
        /// False for HDMI and some USB and virtual devices.
        public let hasVolumeControl: Bool

        public init(id: AudioDeviceID, name: String, hasVolumeControl: Bool) {
            self.id = id
            self.name = name
            self.hasVolumeControl = hasVolumeControl
        }
    }

    /// Last known volume, 0…1, or nil when the target exposes no volume control.
    public private(set) var volume: Double?
    public private(set) var isMuted = false
    /// Name of the device being controlled, for the OSD and the CLI.
    public private(set) var deviceName: String?
    /// Output devices found by the last refresh.
    public private(set) var devices: [OutputDevice] = []
    /// Explicitly chosen device, or nil to follow the system default.
    public private(set) var selectedDevice: AudioDeviceID?
    /// False when the target has no software volume — reads yield nil and writes
    /// change nothing.
    public private(set) var targetHasVolumeControl = false
    /// Fired whenever any of the above changes.
    public var onChange: (() -> Void)?

    /// One media-key step (~6.25%), matching macOS.
    public static let step = MediaKeyRouter.step

    /// Shared instance, matching `DisplayController.shared` /
    /// `HotkeyController.shared`, so the media keys, the OSD and the CLI all
    /// act on the **same** device handle rather than each holding their own.
    public static let shared = SystemVolumeController()

    private let hal: CoreAudioHAL
    private let queue: DispatchQueue
    private var device: AudioDeviceID?

    public init(
        hal: CoreAudioHAL = CoreAudioHal(),
        queue: DispatchQueue = DispatchQueue(label: "dev.fisifla.fbd.systemvolume", qos: .userInitiated)
    ) {
        self.hal = hal
        self.queue = queue
    }

    /// True when the target exposes a volume FBD can actually change.
    public var isControllable: Bool { targetHasVolumeControl }

    /// Point the controller at a specific device, or nil to follow the system
    /// default. Reads back immediately so callers see the new target's state.
    public func select(_ deviceID: AudioDeviceID?) {
        selectedDevice = deviceID
        device = deviceID
        // Clear what was published: it describes the OLD target, and a caller
        // waiting for the new one to arrive must not mistake the stale value for
        // the answer. Without this, reading straight after `--device` reports the
        // previous device.
        deviceName = nil
        volume = nil
        isMuted = false
        targetHasVolumeControl = false
        refresh()
    }

    /// Read the current state and device list, off the UI path.
    public func refresh() {
        let hal = self.hal
        let selected = self.selectedDevice
        queue.async { [weak self] in
            let devices = hal.outputDeviceIDs().map { id in
                OutputDevice(
                    id: id,
                    name: hal.name(of: id) ?? "Unknown device",
                    hasVolumeControl: hal.volume(of: id) != nil
                )
            }
            let device = selected ?? hal.defaultOutputDevice()
            let name = device.flatMap { hal.name(of: $0) }
            let value = device.flatMap { hal.volume(of: $0) }
            let muted = device.flatMap { hal.isMuted($0) } ?? false
            Task { @MainActor in
                guard let self else { return }
                self.devices = devices
                self.device = device
                self.deviceName = name
                self.volume = value
                self.isMuted = muted
                self.targetHasVolumeControl = value != nil
                self.onChange?()
            }
        }
    }

    /// Set the output volume, 0…1. Returns immediately.
    ///
    /// When the target is known to be controllable the value is cached up front
    /// so the HUD moves at once however slow the device is; either way the
    /// device's own answer is what ends up published, so a device that settles
    /// somewhere else is reported truthfully rather than left lying.
    ///
    /// A target with **no** software volume is left alone entirely — no HUD
    /// movement, no claimed change.
    public func set(_ value: Double) {
        let clamped = Self.clamped(value)
        if targetHasVolumeControl {
            volume = clamped
            if clamped > 0, isMuted { isMuted = false }
            onChange?()
        }

        let hal = self.hal
        let known = self.device
        let selected = self.selectedDevice
        queue.async { [weak self] in
            guard let device = selected ?? known ?? hal.defaultOutputDevice() else { return }

            // A device with no scalar volume cannot accept this. Report that
            // rather than claiming a change that the HAL will drop.
            guard hal.volume(of: device) != nil else {
                let name = hal.name(of: device)
                Task { @MainActor in
                    guard let self else { return }
                    self.device = device
                    self.deviceName = name
                    self.volume = nil
                    self.targetHasVolumeControl = false
                    self.onChange?()
                }
                return
            }

            if hal.isMuted(device) == true {
                _ = hal.setMuted(false, on: device)
            }
            _ = hal.setVolume(clamped, on: device)
            // Read back only after the write: this is the round trip a slow USB
            // device makes expensive, and exactly what must not run on the
            // caller's thread.
            let actual = hal.volume(of: device)
            let muted = hal.isMuted(device) ?? false
            let name = hal.name(of: device)
            Task { @MainActor in
                guard let self else { return }
                self.device = device
                self.deviceName = name
                self.targetHasVolumeControl = actual != nil
                self.volume = actual ?? clamped
                self.isMuted = muted
                self.onChange?()
            }
        }
    }

    /// Move by a delta, e.g. one media-key step.
    public func adjust(by delta: Double) {
        set((volume ?? 0.5) + delta)
    }

    public func toggleMute() {
        setMuted(!isMuted)
    }

    public func setMuted(_ muted: Bool) {
        guard targetHasVolumeControl else { return }
        isMuted = muted
        onChange?()

        let hal = self.hal
        let known = self.device
        let selected = self.selectedDevice
        queue.async {
            guard let device = selected ?? known ?? hal.defaultOutputDevice() else { return }
            _ = hal.setMuted(muted, on: device)
        }
    }

    /// Clamp to the useful range. Pure, so the boundary behaviour is testable
    /// without a device.
    public static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
