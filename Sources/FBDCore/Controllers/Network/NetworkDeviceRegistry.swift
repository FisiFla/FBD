import Foundation

/// A saved network device — a TV or AVR the app can address by name instead of
/// repeating brand + host on every command.
///
/// BetterDisplay attaches its smart-device controllers to a display; FBD's
/// network devices are not displays (they have no `CGDirectDisplayID`), so they
/// are kept as a named registry the CLI and the UI both read. That is the honest
/// mapping of the same idea onto FBD's model.
public struct NetworkDevice: Codable, Equatable, Identifiable, Sendable {
    public enum Brand: String, Codable, CaseIterable, Sendable {
        case lg, samsung, philips, yamaha

        /// The word to show a user. FBD's own wording, not a vendor string.
        public var displayName: String {
            switch self {
            case .lg: return "LG webOS"
            case .samsung: return "Samsung"
            case .philips: return "Philips"
            case .yamaha: return "Yamaha"
            }
        }
    }

    /// Stable identifier derived from the name, so a rename is a remove+add
    /// rather than a silent id change.
    public let id: String
    public let name: String
    public let brand: Brand
    public let host: String
    /// Yamaha amplifier zone ("main", "2"…). Nil for the other brands, which
    /// have no zone concept.
    public let zone: String?

    public init(id: String, name: String, brand: Brand, host: String, zone: String? = nil) {
        self.id = id
        self.name = name
        self.brand = brand
        self.host = host
        self.zone = zone
    }
}

/// The saved-network-device registry, persisted as one JSON blob through
/// `Settings.defaults` — the single write path, shared by the app and the CLI.
///
/// The registry is deliberately pure: it validates and stores, and never talks
/// to a device. Reaching one stays the job of the `Network/` controllers.
public enum NetworkDeviceRegistry {
    public enum Failure: Error, Equatable {
        case emptyName
        case duplicateName(String)
        case invalidHost(String)
        case notFound(String)
        case tooMany(Int)

        /// A message suitable for printing to a user.
        public var message: String {
            switch self {
            case .emptyName:
                return "a device name is required"
            case .duplicateName(let name):
                return "a device named '\(name)' already exists"
            case .invalidHost(let host):
                return "'\(host)' is not a usable host — give a hostname or IP address, without a scheme, port or path"
            case .notFound(let name):
                return "no device named '\(name)'"
            case .tooMany(let limit):
                return "the device list is full (\(limit) entries)"
            }
        }
    }

    /// Bound on the persisted list, so a runaway loop cannot grow the blob.
    public static let limit = 32

    // MARK: - Reading

    public static func list(defaults: UserDefaults = Settings.defaults) -> [NetworkDevice] {
        guard let data = defaults.data(forKey: Settings.networkDevicesKey),
              let devices = try? JSONDecoder().decode([NetworkDevice].self, from: data) else {
            return []
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Look a device up by name, case-insensitively.
    public static func device(named name: String, defaults: UserDefaults = Settings.defaults) -> NetworkDevice? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return list(defaults: defaults).first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    // MARK: - Writing

    public static func add(
        name: String,
        brand: NetworkDevice.Brand,
        host: String,
        zone: String? = nil,
        defaults: UserDefaults = Settings.defaults
    ) -> Result<NetworkDevice, Failure> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(.emptyName) }
        guard validatedHost(host) != nil else { return .failure(.invalidHost(host)) }

        var devices = list(defaults: defaults)
        guard !devices.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) else {
            return .failure(.duplicateName(trimmedName))
        }
        guard devices.count < limit else { return .failure(.tooMany(limit)) }

        let trimmedZone = zone?.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = NetworkDevice(
            id: identifier(for: trimmedName),
            name: trimmedName,
            brand: brand,
            host: validatedHost(host) ?? host,
            zone: (trimmedZone?.isEmpty == false) ? trimmedZone : nil
        )
        devices.append(device)
        save(devices, defaults: defaults)
        return .success(device)
    }

    /// Remove by name. Returns false when nothing matched.
    @discardableResult
    public static func remove(named name: String, defaults: UserDefaults = Settings.defaults) -> Bool {
        var devices = list(defaults: defaults)
        let before = devices.count
        devices.removeAll { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
        guard devices.count != before else { return false }
        save(devices, defaults: defaults)
        return true
    }

    // MARK: - Validation

    /// A host the controllers can safely interpolate into a URL.
    ///
    /// Fail-closed: this is a *host*, not a URL, so anything that could change
    /// the request's target is refused — a scheme, a path, credentials, a query,
    /// a fragment, whitespace, or a `:port` suffix (the port is the caller's
    /// parameter, not part of the host). Letters, digits, `.`, `-`, `_` and `:`
    /// are allowed so IPv6 literals still work.
    public static func validatedHost(_ raw: String) -> String? {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count <= 253 else { return nil }
        guard !host.contains("://") else { return nil }
        guard host.rangeOfCharacter(from: CharacterSet(charactersIn: "/@#?\\ \t\n")) == nil else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-_[]")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard !host.hasPrefix("."), !host.hasPrefix("-"), !host.hasSuffix(".") else { return nil }
        // A bracketed literal must close: `[fe80::1` is malformed, and
        // `[fe80::1]:3000` carries a port for the same reason a bare `host:port`
        // does.
        if host.hasPrefix("["), !host.hasSuffix("]") { return nil }
        // `host:8080` is a port in the URL sense; refuse it so the caller passes
        // the port as the parameter it actually is. A bare IPv6 literal has
        // several colons and is not affected by this.
        let colonCount = host.reduce(0) { $0 + ($1 == ":" ? 1 : 0) }
        if colonCount == 1, let colon = host.lastIndex(of: ":") {
            let suffix = host[host.index(after: colon)...]
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return nil }
        }
        return host
    }

    /// A filesystem-and-UserDefaults-safe identifier derived from the name.
    static func identifier(for name: String) -> String {
        let lowered = name.lowercased()
        let mapped = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "device" : collapsed
    }

    private static func save(_ devices: [NetworkDevice], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        defaults.set(data, forKey: Settings.networkDevicesKey)
    }
}
