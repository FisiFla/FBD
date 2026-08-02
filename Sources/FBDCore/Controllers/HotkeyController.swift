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

    public init() {}

    /// Start listening for global media key events.
    public func start() {
        guard !isStarted else { return }
        isStarted = true

        guard CGPreflightListenEventAccess() || CGPreflightPostEventAccess() || AXIsProcessTrusted() else {
            log.warning("HotkeyController: Accessibility/EventTap permission missing — media key interception disabled until granted")
            return
        }

        setupEventTap()
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

    private func setupEventTap() {
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
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.info("HotkeyController: media key event tap installed successfully")
    }

    /// Process a media key code. Returns true if the key was consumed by FBD.
    @MainActor
    fileprivate func handleMediaKey(keyCode: Int32) -> Bool {
        guard Settings.interceptMediaKeys else { return false }

        let displayController = DisplayController.shared
        let displays = displayController.displays
        guard !displays.isEmpty else { return false }

        // Target the display under the mouse cursor, or the primary non-builtin display if any exists
        let mouseLocation = NSEvent.mouseLocation
        let targetDisplay = displays.first { $0.bounds.contains(mouseLocation) }
            ?? displays.first { !$0.isBuiltin }
            ?? displays.first

        guard let targetDisplay else { return false }

        // Only intercept if we have a control path (Apple brightness or DDC)
        guard targetDisplay.appleBrightnessAvailable || targetDisplay.ddcAvailable else { return false }

        let step = 0.0625 // 1/16th (~6.25%) matching macOS standard step

        switch keyCode {
        case 2: // NX_KEYTYPE_BRIGHTNESS_UP
            let current = targetDisplay.brightness ?? displayController.getBrightness(for: targetDisplay) ?? 0.5
            displayController.setBrightness(min(current + step, 1.0), on: targetDisplay)
            return true

        case 3: // NX_KEYTYPE_BRIGHTNESS_DOWN
            let current = targetDisplay.brightness ?? displayController.getBrightness(for: targetDisplay) ?? 0.5
            displayController.setBrightness(max(current - step, 0.0), on: targetDisplay)
            return true

        case 0: // NX_KEYTYPE_SOUND_UP
            if targetDisplay.ddcAvailable {
                let current = displayController.readDDCControls(for: targetDisplay).volume ?? 0.5
                displayController.setVolume(min(current + step, 1.0), on: targetDisplay)
                NotificationCenter.default.post(name: .fbdDisplayUpdated, object: nil, userInfo: ["displayID": targetDisplay.id])
                return true
            }
            return false

        case 1: // NX_KEYTYPE_SOUND_DOWN
            if targetDisplay.ddcAvailable {
                let current = displayController.readDDCControls(for: targetDisplay).volume ?? 0.5
                displayController.setVolume(max(current - step, 0.0), on: targetDisplay)
                NotificationCenter.default.post(name: .fbdDisplayUpdated, object: nil, userInfo: ["displayID": targetDisplay.id])
                return true
            }
            return false

        case 7: // NX_KEYTYPE_MUTE
            if targetDisplay.ddcAvailable {
                let muted = displayController.readDDCControls(for: targetDisplay).muted
                let newMuted = muted == false
                displayController.setMuted(newMuted, on: targetDisplay)
                NotificationCenter.default.post(name: .fbdDisplayUpdated, object: nil, userInfo: ["displayID": targetDisplay.id])
                return true
            }
            return false

        default:
            return false
        }
    }
}

/// Global C callback for CGEventTap media key events.
private func fbdHotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
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
