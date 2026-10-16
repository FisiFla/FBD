import FBDCore
import SwiftUI

struct QuickToggle: Identifiable {
    enum Kind: CaseIterable { case darkMode, nightShift, trueTone, keepAwake }
    let id: Kind
    let isOn: Bool
    let isAvailable: Bool

    var symbol: String {
        switch id {
        case .darkMode: return "circle.lefthalf.filled"
        case .nightShift: return "moon.stars"
        case .trueTone: return "sun.dust"
        case .keepAwake: return "cup.and.saucer"
        }
    }

    var title: LocalizedStringKey {
        switch id {
        case .darkMode: return "Dark Mode"
        case .nightShift: return "Night Shift"
        case .trueTone: return "True Tone"
        case .keepAwake: return "Keep Awake"
        }
    }

    var unavailableReason: LocalizedStringKey? {
        isAvailable ? nil : "Not supported on this Mac"
    }
}

protocol QuickToggleBackend {
    func state(_ kind: QuickToggle.Kind) -> (isOn: Bool, isAvailable: Bool)
    func set(_ kind: QuickToggle.Kind, on: Bool) -> Bool
}

/// FBDCore-backed toggles. Night Shift has no enable call, only a strength, so
/// "on" = strength > 0. Turning it off remembers the last non-zero strength
/// (persisted) and turning it on restores it, defaulting to full strength.
final class SystemQuickToggleBackend: QuickToggleBackend {
    static let nightShiftLastStrengthKey = "panel.nightShiftLastStrength"

    private let nightShift = NightShiftController()
    private let trueTone = TrueToneController()
    private let darkMode = DarkModeController()

    func state(_ kind: QuickToggle.Kind) -> (isOn: Bool, isAvailable: Bool) {
        switch kind {
        case .darkMode: return (darkMode.isDark() ?? false, darkMode.isAvailable)
        case .nightShift: return ((nightShift.strength() ?? 0) > 0, nightShift.isAvailable)
        case .trueTone: return (trueTone.isEnabled() ?? false, trueTone.isAvailable)
        case .keepAwake: return (KeepAwakeController.shared.isEnabled, true)
        }
    }

    func set(_ kind: QuickToggle.Kind, on: Bool) -> Bool {
        switch kind {
        case .darkMode: return darkMode.setDark(on)
        case .nightShift: return setNightShift(on)
        case .trueTone: return trueTone.setEnabled(on)
        case .keepAwake: return KeepAwakeController.shared.setEnabled(on)
        }
    }

    private func setNightShift(_ on: Bool) -> Bool {
        let defaults = Settings.defaults
        let key = Self.nightShiftLastStrengthKey
        if on {
            let remembered = defaults.double(forKey: key)
            return nightShift.setStrength(remembered > 0 ? remembered : 1)
        }
        if let current = nightShift.strength(), current > 0 {
            defaults.set(current, forKey: key)
        }
        return nightShift.setStrength(0)
    }
}
