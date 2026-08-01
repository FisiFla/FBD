import Foundation

/// Centralized UserDefaults-backed settings. Keys mirror the semantics of the
/// BetterDisplay settings surface (see betterdisplay-reverse-engineering.md).
public enum Settings {
    private static let defaults = UserDefaults.standard
    private static let suite = "dev.fisifla.fbd"

    // MARK: DDC

    /// Minimum delay between consecutive DDC writes per display, milliseconds.
    @Storage(key: "ddcBacklightCoolOffMilliseconds", defaultValue: 1000)
    public static var ddcCooldownMilliseconds: Int

    /// Debounce window for brightness slider writes, milliseconds.
    @Storage(key: "brightnessDebounceMilliseconds", defaultValue: 100)
    public static var brightnessDebounceMilliseconds: Int

    /// Allow applying modes outside the safe-mode flag set (experimental).
    @Storage(key: "allowUnsafeInvalidModes", defaultValue: false)
    public static var allowUnsafeInvalidModes: Bool

    /// Auto-configure DDC features from the capabilities reply on first connect.
    @Storage(key: "ddcAutoConfigure", defaultValue: true)
    public static var ddcAutoConfigure: Bool

    // MARK: App

    /// Launch at login (menu-bar setting; implemented in the app target).
    @Storage(key: "launchAtLogin", defaultValue: false)
    public static var launchAtLogin: Bool

    /// Show DDC-unavailable warning banner in the menu.
    @Storage(key: "showRosettaWarning", defaultValue: true)
    public static var showRosettaWarning: Bool

    /// Per-display persisted DDC feature availability (VCP codes), keyed by display identity.
    public static func ddcFeatures(for identity: String) -> Set<UInt8> {
        let key = "ddcFeatures.\(identity)"
        let raw = defaults.array(forKey: key) as? [Int] ?? []
        return Set(raw.map { UInt8($0) })
    }

    public static func setDDCFeatures(_ features: Set<UInt8>, for identity: String) {
        let key = "ddcFeatures.\(identity)"
        defaults.set(features.map { Int($0) }.sorted(), forKey: key)
    }

    public static func clearDDCFeatures(for identity: String) {
        defaults.removeObject(forKey: "ddcFeatures.\(identity)")
    }
}

/// Property-wrapper helper backing a UserDefaults key.
@propertyWrapper
public struct Storage<T> {
    private let key: String
    private let defaultValue: T
    private let defaults: UserDefaults

    public init(key: String, defaultValue: T, suite: String = "dev.fisifla.fbd") {
        self.key = key
        self.defaultValue = defaultValue
        self.defaults = UserDefaults(suiteName: suite) ?? .standard
    }

    public var wrappedValue: T {
        get { defaults.object(forKey: key) as? T ?? defaultValue }
        set { defaults.set(newValue, forKey: key) }
    }
}
