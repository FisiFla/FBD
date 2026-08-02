import Foundation
import Security

/// Centralized UserDefaults-backed settings. Keys mirror the semantics of the
/// BetterDisplay settings surface (see betterdisplay-reverse-engineering.md).
public enum Settings {
    /// The app bundle's standard domain IS dev.fisifla.fbd; anything else
    /// (CLI, tests) must target the suite explicitly so both read the same plist.
    private static var defaults: UserDefaults {
        if Bundle.main.bundleIdentifier == "dev.fisifla.fbd" {
            return .standard
        }
        return UserDefaults(suiteName: suite) ?? .standard
    }
    private static let suite = "dev.fisifla.fbd"

    // MARK: DDC

    /// Minimum delay between consecutive DDC writes per display, milliseconds.
    @Storage(key: "ddcBacklightCoolOffMilliseconds", defaultValue: 1000)
    public static var ddcCooldownMilliseconds: Int

    /// Debounce window for brightness slider writes, milliseconds.
    @Storage(key: "brightnessDebounceMilliseconds", defaultValue: 100)
    public static var brightnessDebounceMilliseconds: Int

    /// Intercept F1/F2 and F10/F11/F12 media keys for external displays.
    @Storage(key: "interceptMediaKeys", defaultValue: true)
    public static var interceptMediaKeys: Bool

    /// Allow applying modes outside the safe-mode flag set (experimental).
    @Storage(key: "allowUnsafeInvalidModes", defaultValue: false)
    public static var allowUnsafeInvalidModes: Bool

    /// Auto-configure DDC features from the capabilities reply on first connect.
    @Storage(key: "ddcAutoConfigure", defaultValue: true)
    public static var ddcAutoConfigure: Bool

    /// Extra attempts after the first for a VCP read (some displays only
    /// answer on the 2nd-3rd try). Total attempts = retries + 1.
    @Storage(key: "ddcReadRetries", defaultValue: 2)
    public static var ddcReadRetries: Int

    /// Settle time between DDC request write and reply read, milliseconds
    /// (some displays need 50-100 ms).
    @Storage(key: "ddcSettleMilliseconds", defaultValue: 30)
    public static var ddcSettleMilliseconds: Int

    // MARK: XDR/HDR (Tier 2)

    /// Target for native XDR upscaling in nits (built-in XDR panel: up to 1600).
    @Storage(key: "xdrUpscaleTargetNits", defaultValue: 1600)
    public static var xdrUpscaleTargetNits: Int

    /// Clamp for the upscale target relative to the display's HDR maximum.
    @Storage(key: "xdrUpscaleMaxFactor", defaultValue: 3)
    public static var xdrUpscaleMaxFactor: Double

    /// Use the Metal software upscaling overlay when native upscaling is unavailable.
    @Storage(key: "softwareUpscalingEnabled", defaultValue: false)
    public static var softwareUpscalingEnabled: Bool

    /// Combine hardware + software + XDR upscaling into one brightness slider.
    @Storage(key: "combinedBrightnessEnabled", defaultValue: false)
    public static var combinedBrightnessEnabled: Bool

    /// Dim-to-black (allows turning the panel fully black via software).
    @Storage(key: "dimToBlackEnabled", defaultValue: false)
    public static var dimToBlackEnabled: Bool

    /// Allow the experimental direct color-table method (entitlement-gated on
    /// macOS 26+; has no effect there).
    @Storage(key: "allowExperimentalDirectXDR", defaultValue: false)
    public static var allowExperimentalDirectXDR: Bool

    // MARK: Virtual displays & layout (Tier 3)

    /// Reconnect virtual screens after wake / app start.
    @Storage(key: "reconnectVirtualScreensOnWake", defaultValue: true)
    public static var reconnectVirtualScreensOnWake: Bool

    /// Disconnect virtual screens while the session is locked.
    @Storage(key: "disconnectVirtualScreensOnLock", defaultValue: false)
    public static var disconnectVirtualScreensOnLock: Bool

    /// Auto-disconnect the built-in display when an external display connects
    /// (Apple Silicon only; experimental).
    @Storage(key: "autoDisconnectBuiltInOnExternal", defaultValue: false)
    public static var autoDisconnectBuiltInOnExternal: Bool

    /// Re-apply the saved display arrangement when the layout changes.
    @Storage(key: "layoutProtectionEnabled", defaultValue: false)
    public static var layoutProtectionEnabled: Bool

    /// Persisted virtual screen configurations (JSON-encoded).
    private static let virtualScreensKey = "virtualScreens.v1"

    public static func loadVirtualScreens() -> [VirtualScreenConfig] {
        guard let data = defaults.data(forKey: virtualScreensKey),
              let configs = try? JSONDecoder().decode([VirtualScreenConfig].self, from: data) else {
            return []
        }
        return configs
    }

    public static func saveVirtualScreens(_ configs: [VirtualScreenConfig]) {
        if let data = try? JSONEncoder().encode(configs) {
            defaults.set(data, forKey: virtualScreensKey)
        }
    }

    // MARK: Integrations (Tier 5)

    /// Enable the local HTTP control API.
    /// Display IDs currently registered as FBD-created virtual screens
    /// (persisted so the CLI and other processes see them too).
    @Storage(key: "virtualDisplayIDs", defaultValue: [])
    public static var virtualDisplayIDs: [UInt32]

    @Storage(key: "httpServerEnabled", defaultValue: false)
    public static var httpServerEnabled: Bool

    /// Port for the HTTP control API (0 = ephemeral).
    @Storage(key: "httpServerPort", defaultValue: 0)
    public static var httpServerPort: Int

    /// ACTUAL listening port of the running app's HTTP API (0 = not running).
    /// Written by the app after the server starts so fbdcli can discover an
    /// ephemeral port; never read by the app itself.
    @Storage(key: "httpServerActivePort", defaultValue: 0)
    public static var httpServerActivePort: Int

    /// Bearer token for the HTTP control API, generated on first access and
    /// persisted. The CLI reads the same defaults domain, so routing works
    /// without any user setup.
    public static var httpAPIToken: String {
        if let token = defaults.string(forKey: "httpAPIToken"), !token.isEmpty {
            return token
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // Extremely unlikely; fall back to a time-seeded token rather
            // than failing closed on a localhost-only API.
            let seed = "\(Date().timeIntervalSince1970)-\(ProcessInfo.processInfo.processIdentifier)"
            return Data(seed.utf8).base64EncodedString()
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        defaults.set(token, forKey: "httpAPIToken")
        return token
    }

    /// Show the custom brightness/volume OSD overlay.
    @Storage(key: "customOSDEnabled", defaultValue: true)
    public static var customOSDEnabled: Bool

    /// Persisted LG webOS client key (granted on first pairing).
    @Storage(key: "tvLGClientKey", defaultValue: "")
    public static var tvLGClientKey: String

    // MARK: EDID & config protection (Tier 4)

    /// Auto-apply a custom EDID when the display connects.
    @Storage(key: "autoApplyEDIDOverride", defaultValue: false)
    public static var autoApplyEDIDOverride: Bool

    /// Restore the factory EDID when the app quits (identity preservation).
    @Storage(key: "restoreFactoryEDIDOnQuit", defaultValue: true)
    public static var restoreFactoryEDIDOnQuit: Bool

    /// Re-apply the saved resolution/preset/brightness when a display reconnects.
    @Storage(key: "configProtectionEnabled", defaultValue: false)
    public static var configProtectionEnabled: Bool

    /// Persisted custom EDID per display identity (key: "edidOverride.<identity>", Data).
    public static func edidOverride(for identity: String) -> Data? {
        defaults.data(forKey: "edidOverride.\(identity)")
    }

    public static func setEDIDOverride(_ data: Data?, for identity: String) {
        if let data {
            defaults.set(data, forKey: "edidOverride.\(identity)")
        } else {
            defaults.removeObject(forKey: "edidOverride.\(identity)")
        }
    }

    /// Persisted layout anchors (JSON-encoded).
    private static let layoutAnchorsKey = "layoutAnchors.v1"

    public static func loadLayoutAnchors() -> [LayoutAnchor] {
        guard let data = defaults.data(forKey: layoutAnchorsKey),
              let anchors = try? JSONDecoder().decode([LayoutAnchor].self, from: data) else {
            return []
        }
        return anchors
    }

    public static func saveLayoutAnchors(_ anchors: [LayoutAnchor]) {
        if let data = try? JSONEncoder().encode(anchors) {
            defaults.set(data, forKey: layoutAnchorsKey)
        }
    }

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
        // Inside the app bundle, standard defaults already use the suite domain
        // (bundle id); using an explicit suite of the same name is broken.
        // Custom suites (tests) always use the suite.
        if suite == "dev.fisifla.fbd" && Bundle.main.bundleIdentifier == "dev.fisifla.fbd" {
            self.defaults = .standard
        } else {
            self.defaults = UserDefaults(suiteName: suite) ?? .standard
        }
    }

    public var wrappedValue: T {
        get { defaults.object(forKey: key) as? T ?? defaultValue }
        set { defaults.set(newValue, forKey: key) }
    }
}
