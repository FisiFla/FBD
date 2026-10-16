import FBDCLIParser
import FBDCore
import CoreGraphics
import Foundation

// MARK: - OSD (Tier 5)

/// `fbdcli osd <icon> <0-100>` — show a transient OSD HUD (e.g. sun.max,
/// speaker.wave.2) at the given percentage. Keeps the process alive for the
/// HUD's ~1.2 s auto-hide window.
@MainActor
func cmdOSD(args: [String]) -> Int32 {
    guard requireArgCount(args, 2, usage: "fbdcli: osd: expected <icon> <0-100> (e.g. 'fbdcli osd sun.max 50')") else { return 1 }
    guard let value = parsePercent(args[1], command: "osd") else { return 1 }
    let osd = CustomOSD()
    if !Settings.customOSDEnabled {
        print("note: custom OSD is disabled in Settings — nothing will be shown")
    }
    osd.show(icon: args[0], value: value / 100.0)
    print("osd: showing '\(args[0])' at \(Int(value))%")
    let deadline = Date().addingTimeInterval(1.5)
    while osd.isVisible, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return 0
}

// MARK: - Night Shift (Tier 5)

/// `fbdcli nightshift [0-100]` — get or set Night Shift strength.
@MainActor
func cmdNightShift(args: [String]) -> Int32 {
    let controller = NightShiftController()
    guard controller.isAvailable else {
        print("nightshift: unavailable on this Mac")
        return 2
    }
    if let arg = args.first {
        guard let value = parsePercent(arg, command: "nightshift") else { return 1 }
        guard controller.setStrength(value / 100.0) else {
            print("fbdcli: nightshift: failed to set strength")
            return 2
        }
    }
    guard let strength = controller.strength() else {
        print("fbdcli: nightshift: failed to read strength")
        return 2
    }
    print(String(format: "nightshift = %.1f%%", strength * 100))
    return 0
}

// MARK: - Dark Mode

/// `fbdcli dark-mode [on|off]` — read or switch the system appearance.
///
/// The same switch Control Center flips, so it is deliberately not stored anywhere: the system
/// owns it and another app can change it, which a remembered copy would misreport.
@MainActor
func cmdDarkMode(args: [String]) -> Int32 {
    let controller = DarkModeController()
    guard controller.isAvailable else {
        print("dark-mode: unavailable on this Mac")
        return 2
    }
    guard let request = DarkModeRequest.parse(args.first) else {
        print("fbdcli: dark-mode: expected on or off (got '\(args.first ?? "")')")
        return 1
    }
    switch request {
    case .on:
        guard controller.setDark(true) else {
            print("fbdcli: dark-mode: failed to switch")
            return 2
        }
    case .off:
        guard controller.setDark(false) else {
            print("fbdcli: dark-mode: failed to switch")
            return 2
        }
    case .report:
        break
    }
    guard let dark = controller.isDark() else {
        print("fbdcli: dark-mode: failed to read the appearance")
        return 2
    }
    print("dark-mode = \(dark ? "on" : "off")")
    return 0
}

// MARK: - True Tone (Tier 5)

/// `fbdcli truetone [on|off]` — get or set True Tone.
@MainActor
func cmdTrueTone(args: [String]) -> Int32 {
    let controller = TrueToneController()
    guard controller.isAvailable else {
        print("truetone: unavailable on this Mac")
        return 2
    }
    if let arg = args.first {
        let enabled: Bool
        switch arg {
        case "on": enabled = true
        case "off": enabled = false
        default:
            print("fbdcli: truetone: expected on or off (got '\(arg)')")
            return 1
        }
        guard controller.setEnabled(enabled) else {
            print("fbdcli: truetone: failed to set True Tone")
            return 2
        }
    }
    guard let enabled = controller.isEnabled() else {
        print("fbdcli: truetone: failed to read state")
        return 2
    }
    print("truetone = \(enabled ? "on" : "off")")
    return 0
}

// MARK: - Ambient-light auto-brightness (Tier 1 #12)

/// `fbdcli ambient-light <display> [on|off]` — get or set the Apple display's
/// ambient-light auto-brightness.
///
/// Reading already answers the capability question: `isAmbientLightCompensationEnabled`
/// returns nil when the display has no ambient-light sensor, which is the same
/// condition the panel's More menu gates its toggle on. A set is confirmed by
/// reading the state back rather than by trusting the write, because the private
/// call reports only a status code and the panel is the authority on what it
/// actually applied.
@MainActor
func cmdAmbientLight(_ controller: DisplayController, display: Display, args: [String]) -> Int32 {
    guard controller.isAmbientLightCompensationEnabled(on: display) != nil else {
        print("ambient-light: unavailable on display \(display.id) (no ambient-light sensor)")
        return 2
    }
    if args.count >= 2 {
        let wanted: Bool
        switch args[1] {
        case "on": wanted = true
        case "off": wanted = false
        default:
            print("fbdcli: ambient-light: expected on or off (got '\(args[1])')")
            return 1
        }
        let current = controller.isAmbientLightCompensationEnabled(on: display)
        if current != wanted {
            controller.setAmbientLightCompensation(wanted, on: display)
        }
    }
    guard let enabled = controller.isAmbientLightCompensationEnabled(on: display) else {
        print("fbdcli: ambient-light: failed to read state for display \(display.id)")
        return 2
    }
    print("ambient-light \(display.id) = \(enabled ? "on" : "off")")
    return 0
}
