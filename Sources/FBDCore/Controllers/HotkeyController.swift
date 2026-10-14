import AppKit
import CoreGraphics
import Foundation
import os

/// Global hotkey and media key controller.
///
/// Intercepts hardware media keys (F1/F2 Brightness Down/Up, F10/F11/F12 Mute/Volume Down/Up)
/// on macOS via `CGEventTap` when `Settings.interceptMediaKeys` is enabled.
/// Adjusts the target external or Apple display's brightness/volume and notifies CustomOSD.
@MainActor
public final class HotkeyController {
    public static let shared = HotkeyController()
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "HotkeyController")
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isStarted = false
    private var activationObserver: NSObjectProtocol?

    public init() {
        // Retry installation when the user returns to the app after granting
        // Accessibility/Input Monitoring in System Settings.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryIfNeeded() }
        }
    }

    private func retryIfNeeded() {
        guard !isStarted else { return }
        start()
    }

    /// Start listening for global media key events. Only marks the controller
    /// started when the tap is actually installed and enabled; permission
    /// failures leave it retryable (see retryIfNeeded).
    public func start() {
        guard !isStarted else { return }
        guard CGPreflightListenEventAccess() || CGPreflightPostEventAccess() || AXIsProcessTrusted() else {
            log.warning("HotkeyController: Accessibility/EventTap permission missing — media key interception disabled until granted")
            postUnavailable()
            return
        }
        if setupEventTap() {
            isStarted = true
        }
    }

    /// Stop media key interception.
    public func stop() {
        guard isStarted else { return }
        isStarted = false

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
    }

    private func setupEventTap() -> Bool {
        let sysDefinedRaw: UInt32 = 14
        let mask: CGEventMask = 1 << sysDefinedRaw

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: fbdHotkeyTapCallback,
            userInfo: nil
        ) else {
            log.warning("HotkeyController: CGEventTap creation failed")
            postUnavailable()
            return false
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            // Tap creation can succeed while the system refuses to enable it
            // (permission revoked mid-session, lockdown policies).
            log.error("HotkeyController: event tap created but did not enable")
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.runLoopSource = nil
            self.eventTap = nil
            postUnavailable()
            return false
        }
        log.info("HotkeyController: media key event tap installed successfully")
        return true
    }

    /// Re-enable a tap the system suspended (tapDisabledByTimeout).
    @MainActor
    func reenableTap() -> Bool {
        guard let eventTap else { return false }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        if CGEvent.tapIsEnabled(tap: eventTap) {
            log.info("HotkeyController: event tap re-enabled after suspension")
            return true
        }
        log.error("HotkeyController: event tap re-enable failed")
        postUnavailable()
        return false
    }

    /// A tap disabled by user input usually means permission was revoked.
    @MainActor
    fileprivate func handleTapDisabledByUser() {
        log.error("HotkeyController: event tap disabled by user input (permission revoked?)")
        postUnavailable()
    }

    /// Surface the unavailable state to the UI (Settings hint).
    private func postUnavailable() {
        NotificationCenter.default.post(name: .fbdHotkeysUnavailable, object: nil)
    }

    /// Process a media key code. Returns true if the key was consumed by FBD.
    @MainActor
    fileprivate func handleMediaKey(keyCode: Int32) -> Bool {
        let displayController = DisplayController.shared
        let displays = displayController.displays
        guard !displays.isEmpty else { return false }

        // Which screen the keys act on is the user's configured control target.
        // The default, `.mouseScreen`, reproduces the historical "under the
        // pointer, else the primary non-builtin display" behaviour exactly, so
        // this changes nothing for anyone who has not touched the setting --
        // and the fallback below keeps the guarantee that a press is never
        // silently swallowed.
        let mouseLocation = NSEvent.mouseLocation
        let systemAudio = SystemVolumeController.shared
        // Which capability the key needs decides which candidates are eligible.
        let requiresVolume = keyCode == 0 || keyCode == 1 || keyCode == 7
        let resolved = KeyboardControlResolver.resolve(
            target: Settings.keyboardControlTarget,
            candidates: displays.map { display in
                ScreenCandidate(
                    displayID: display.id,
                    name: display.name,
                    frame: display.bounds,
                    supportsBrightness: display.appleBrightnessAvailable || display.ddcAvailable,
                    supportsVolume: display.ddcAvailable,
                    isMain: CGDisplayIsMain(display.id) != 0,
                    isOnline: display.isOnline
                )
            },
            mouseLocation: mouseLocation,
            focusedDisplayID: Self.focusedDisplayID(in: displays),
            audioDeviceName: systemAudio.deviceName,
            requiresVolume: requiresVolume
        ).compactMap { id in displays.first { $0.id == id } }

        let targetDisplays = resolved.isEmpty
            ? [displays.first { $0.bounds.contains(mouseLocation) }
                ?? displays.first { !$0.isBuiltin }
                ?? displays[0]]
            : resolved
        guard let targetDisplay = targetDisplays.first else { return false }

        // Pure routing decision (unit-tested in MediaKeyRouterTests); the
        // event is only consumed when an action is returned.
        let decision = MediaKeyRouter.decide(
            keyCode: keyCode,
            interceptEnabled: Settings.interceptMediaKeys,
            targetHasControlPath: targetDisplay.appleBrightnessAvailable || targetDisplay.ddcAvailable,
            targetHasDDC: targetDisplay.ddcAvailable,
            // The Mac's own output volume is the fallback route for volume keys
            // when the display has no DDC (#20).
            systemVolumeAvailable: systemAudio.isControllable
        )
        let action = decision.action

        let step = MediaKeyRouter.step

        // A target may resolve to more than one screen (`.allSuitableScreens`),
        // so brightness is applied to each. Volume follows the router's single
        // decision: DDC per screen, or the Mac's own output once.
        func adjustBrightness(by delta: Double) {
            for display in targetDisplays {
                let current = display.brightness
                    ?? displayController.getBrightness(for: display)
                    ?? 0.5
                displayController.setBrightness(min(max(current + delta, 0.0), 1.0), on: display)
            }
        }

        switch action {
        case .none:
            return false

        case .brightnessUp:
            adjustBrightness(by: step)
            return true

        case .brightnessDown:
            adjustBrightness(by: -step)
            return true

        case .volumeUp, .volumeDown, .toggleMute:
            // Which path the key takes is the router's decision, not this
            // switch's: DDC when the display has it, otherwise the Mac's own
            // output (#20).
            guard let volumeTarget = decision.volumeTarget else { return false }
            switch volumeTarget {
            case .display:
                for display in targetDisplays {
                    let controls = displayController.readDDCControls(for: display)
                    // The value the display was moved *to*, so an attached device can
                    // follow it without re-reading the display.
                    var routedVolume: Double?
                    switch action {
                    case .volumeUp:
                        let value = min((controls.volume ?? 0.5) + step, 1.0)
                        displayController.setVolume(value, on: display)
                        routedVolume = value
                    case .volumeDown:
                        let value = max((controls.volume ?? 0.5) - step, 0.0)
                        displayController.setVolume(value, on: display)
                        routedVolume = value
                    default:
                        displayController.setMuted(controls.muted == false, on: display)
                    }
                    // A display with a TV or AVR attached drives that device too —
                    // which is what attaching one means. Fire and forget: a media
                    // key press must not block on a network round trip, and the
                    // device reports its own failures through its controller.
                    if let routedVolume,
                       let device = NetworkDeviceAttachment.device(forDisplay: display.identityKey) {
                        Self.deviceCommander.setVolume(
                            percent: NetworkDeviceVolume.percent(fromDisplayVolume: routedVolume),
                            on: device,
                            completion: nil
                        )
                    }
                    NotificationCenter.default.post(
                        name: .fbdDisplayUpdated, object: nil, userInfo: ["displayID": display.id]
                    )
                }
            case .system:
                switch action {
                case .volumeUp: systemAudio.adjust(by: step)
                case .volumeDown: systemAudio.adjust(by: -step)
                default: systemAudio.toggleMute()
                }
            }
            return true
        }
    }

    /// The display whose screen holds the key window (`NSScreen.main`), matched
    /// against the display list by frame. Nil when nothing matches, which the
    /// resolver then falls back from.
    @MainActor
    private static func focusedDisplayID(in displays: [Display]) -> CGDirectDisplayID? {
        guard let frame = NSScreen.main?.frame else { return nil }
        return displays.first { $0.bounds.equalTo(frame) }?.id
            ?? displays.first { $0.bounds.intersects(frame) }?.id
    }

    /// Sends an attached network device's volume. Static so a media-key press does
    /// not build a controller each time; `NetworkDeviceCommander` holds no state.
    private static let deviceCommander = NetworkDeviceCommander()
}

/// Global C callback for CGEventTap media key events.
private func fbdHotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Tap lifecycle events: the system suspends taps on timeout (recoverable)
    // or when the user revokes permissions (not recoverable without re-grant).
    switch type {
    case .tapDisabledByTimeout:
        // The tap's run-loop source runs on the main run loop.
        _ = MainActor.assumeIsolated { HotkeyController.shared.reenableTap() }
        return nil
    case .tapDisabledByUserInput:
        MainActor.assumeIsolated { HotkeyController.shared.handleTapDisabledByUser() }
        return nil
    default:
        break
    }

    guard type.rawValue == 14 else { // sysDefined
        return Unmanaged.passUnretained(event)
    }

    let nsEvent = NSEvent(cgEvent: event)
    guard let nsEvent, nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }

    let data1 = nsEvent.data1
    let keyCode = Int32((data1 & 0xFFFF0000) >> 16)
    let keyFlags = (data1 & 0x0000FFFF)
    let keyState = (keyFlags & 0xFF00) >> 8
    let isKeyDown = keyState == 0xA
    let isRepeat = (keyFlags & 0x1) != 0

    guard isKeyDown || isRepeat else {
        return Unmanaged.passUnretained(event)
    }

    var consumed = false
    if Thread.isMainThread {
        consumed = MainActor.assumeIsolated {
            HotkeyController.shared.handleMediaKey(keyCode: keyCode)
        }
    } else {
        DispatchQueue.main.sync {
            consumed = MainActor.assumeIsolated {
                HotkeyController.shared.handleMediaKey(keyCode: keyCode)
            }
        }
    }

    if consumed {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
