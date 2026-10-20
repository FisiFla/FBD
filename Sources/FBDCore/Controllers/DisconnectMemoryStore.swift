import Foundation
import os

/// The displays the user asked to keep disconnected.
///
/// A disconnect is a **setting**, not an event: the person who turns the desk
/// screen off wants it off every time — after a reboot, after a replug, after
/// FBD is restarted. This store is where that request is kept, and it is
/// injected so a test can prove the behaviour survives a "restart" (a new
/// controller over the same store) without a real display attached.
public protocol DisconnectMemoryStoring: AnyObject {
    /// Whether the display with this identity key is remembered as "keep disconnected".
    func isRemembered(_ identityKey: String) -> Bool
    /// Remember the display: it is disconnected again whenever it comes back.
    func remember(_ identityKey: String)
    /// Forget the display: it stays connected from now on.
    func forget(_ identityKey: String)
    /// Every remembered identity key.
    func rememberedIdentities() -> [String]
}

/// The UserDefaults-backed store.
///
/// One JSON value per display, under `disconnectMemory.<identityKey>` — the
/// same per-display shape as `Settings.storedBrightness(for:in:)` and
/// `Settings.ddcFeatures(for:)`. A display nobody remembered has no key at
/// all, which is what "not remembered" looks like on disk.
///
/// The identity key is the display's `Display.identityKey` (vendor, model and
/// serial by default), so the memory follows the *display* and not the
/// display id, which changes on every replug.
public final class UserDefaultsDisconnectMemoryStore: DisconnectMemoryStoring {
    /// The key prefix every remembered display is filed under.
    public static let keyPrefix = "disconnectMemory."

    private let defaults: UserDefaults
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "DisconnectMemory")

    public init(defaults: UserDefaults = Settings.defaults) {
        self.defaults = defaults
    }

    private func key(for identityKey: String) -> String {
        Self.keyPrefix + identityKey
    }

    public func isRemembered(_ identityKey: String) -> Bool {
        guard let data = defaults.data(forKey: key(for: identityKey)),
              let value = try? JSONDecoder().decode(Bool.self, from: data) else {
            return false
        }
        return value
    }

    public func remember(_ identityKey: String) {
        guard let data = try? JSONEncoder().encode(true) else {
            log.error("remember: could not encode the value for \(identityKey)")
            return
        }
        defaults.set(data, forKey: key(for: identityKey))
        log.debug("remember: \(identityKey) is disconnected again whenever it comes back")
    }

    public func forget(_ identityKey: String) {
        defaults.removeObject(forKey: key(for: identityKey))
        log.debug("forget: \(identityKey) stays connected from now on")
    }

    public func rememberedIdentities() -> [String] {
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.keyPrefix) }
            .map { String($0.dropFirst(Self.keyPrefix.count)) }
            .sorted()
    }
}
