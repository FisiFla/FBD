import CoreGraphics
import Foundation

/// The icon a preset shows in Settings and the menu.
///
/// A closed set for the same reason `MenuBarIconStyle` is closed: only names
/// measured to resolve on macOS 27 are offered, so a preset can never render as
/// a blank swatch. Unlike that type this one decodes leniently — an
/// unrecognised stored name degrades to ``default`` rather than throwing, so a
/// symbol renamed in a future version cannot make every preset unreadable.
public enum DisplayPresetSymbol: String, CaseIterable, Sendable {
    case display
    case laptop = "laptopcomputer"
    case screen = "tv"
    case film
    case game = "gamecontroller"
    case work = "briefcase"
    case contrast = "circle.lefthalf.filled"
    case night = "moon.stars"
    case bright = "sun.max"
    case colour = "paintpalette"
    case hidden = "eye.slash"
    case sparkle = "sparkles"

    /// The icon a preset gets when none is chosen, and the one an unrecognised
    /// stored name degrades to.
    public static let `default`: DisplayPresetSymbol = .display

    /// The curated set, in the order the picker offers it.
    public static let all: [DisplayPresetSymbol] = allCases

    public static func resolve(_ name: String?) -> DisplayPresetSymbol {
        guard let name, let symbol = DisplayPresetSymbol(rawValue: name) else { return .default }
        return symbol
    }

    /// The SF Symbol name for `NSImage(systemSymbolName:)`.
    public var symbolName: String { rawValue }

    /// The picker/row label. Deliberately plain strings, exactly like
    /// `MenuBarIconStyle.label` — these name icons, not actions.
    public var label: String {
        switch self {
        case .display: return "Display"
        case .laptop: return "Laptop"
        case .screen: return "TV"
        case .film: return "Film"
        case .game: return "Game"
        case .work: return "Work"
        case .contrast: return "Contrast"
        case .night: return "Night"
        case .bright: return "Bright"
        case .colour: return "Colour"
        case .hidden: return "Hidden"
        case .sparkle: return "Sparkle"
        }
    }
}

extension DisplayPresetSymbol: Codable {
    /// Decodes leniently: an unknown stored name becomes ``default`` so one bad
    /// value cannot make a preset undecodable.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DisplayPresetSymbol.resolve(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(symbolName)
    }
}

extension DisplayPresetSymbol {
    /// The symbol a *typed* name refers to: the SF Symbol name (`tv`), the case
    /// name (`screen`) or the picker label (`TV`), matched case-insensitively.
    ///
    /// Unlike ``resolve(_:)``, which degrades quietly because it decodes values
    /// this app wrote, this is strict and returns `nil` for anything else: a
    /// person typing a flag or a name wants to hear about a typo rather than
    /// silently get the default icon.
    public static func named(_ raw: String) -> DisplayPresetSymbol? {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return nil }
        return DisplayPresetSymbol.all.first {
            $0.symbolName.lowercased() == name
                || $0.label.lowercased() == name
                || String(describing: $0).lowercased() == name
        }
    }
}

/// One named display preset: a captured `DisplayStateSnapshot` plus the
/// properties to re-apply, stored per display identity.
///
/// A preset is FBD's own record, not a display's — that is why its identity is
/// display-independent and why it stores what was captured even for properties
/// the user later narrows out of `properties`: re-widening the selection never
/// requires re-saving the preset.
public struct DisplayPreset: Codable, Equatable, Identifiable {
    /// The most a name may hold, after trimming. Long enough for a real label,
    /// short enough that the row and CLI list stay readable.
    public static let maximumNameLength = 64

    public let id: UUID
    public var name: String
    public var symbol: DisplayPresetSymbol
    /// Which captured properties applying this preset re-applies.
    public var properties: ProtectedProperties
    /// The state captured when the preset was saved.
    public var state: DisplayStateSnapshot

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: DisplayPresetSymbol = .default,
        properties: ProtectedProperties = DisplayPresets.defaultProperties,
        state: DisplayStateSnapshot
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.properties = properties
        self.state = state
    }
}

/// What applying a preset did, per property.
///
/// Reported rather than assumed: a preset saved on a display that has since
/// lost a capability (an HDR panel moved to another machine, a TV that stopped
/// reporting its input) applies what it can and says what it could not, so
/// neither the UI nor the CLI has to pretend the whole preset landed.
public struct DisplayPresetOutcome: Equatable {
    /// The properties the preset asked to re-apply.
    public let requested: ProtectedProperties
    /// Those this display no longer exposes, so they were skipped.
    public let unavailable: ProtectedProperties

    public init(requested: ProtectedProperties, unavailable: ProtectedProperties) {
        self.requested = requested
        self.unavailable = unavailable
    }

    /// What was handed to the display's seams: `requested` less `unavailable`.
    public var applied: ProtectedProperties { requested.subtracting(unavailable) }
}

/// Named display presets: a per-identity list of captured display states,
/// persisted as JSON in `UserDefaults` under `"displayPresets.<identity>"` —
/// the same storage shape and suite `ModeFavourites` uses.
///
/// Identity, not display id: a preset survives a reconnect that renumbers the
/// display, exactly as the config-protection blob and resolution favourites do.
public enum DisplayPresets {
    /// What a preset re-applies unless the caller narrows it: `all` less
    /// `.mainStatus`.
    ///
    /// Making one display the main display displaces another, so a preset the
    /// user applies should not silently move the menu bar to a different screen.
    /// `mainStatus` stays selectable — a preset may still protect it — it is just
    /// not part of the default.
    public static let defaultProperties: ProtectedProperties = ProtectedProperties.all.subtracting(.mainStatus)

    /// UserDefaults key for a display identity's presets (a JSON array).
    static func defaultsKey(for identity: String) -> String { "displayPresets.\(identity)" }

    // MARK: - Reading

    /// Every preset for `identity`, in the order they were saved.
    public static func presets(
        for identity: String,
        defaults: UserDefaults = Settings.defaults
    ) -> [DisplayPreset] {
        stored(for: identity, defaults: defaults)
    }

    /// The preset with `id`, or nil.
    public static func preset(
        id: UUID,
        for identity: String,
        defaults: UserDefaults = Settings.defaults
    ) -> DisplayPreset? {
        stored(for: identity, defaults: defaults).first { $0.id == id }
    }

    /// The preset named `name` (trimmed, case-insensitive), or nil. Names are
    /// unique per identity — see `save` — so this is never ambiguous.
    public static func preset(
        named name: String,
        for identity: String,
        defaults: UserDefaults = Settings.defaults
    ) -> DisplayPreset? {
        stored(for: identity, defaults: defaults).first { matchesName($0.name, name) }
    }

    /// Resolve a user-supplied reference: a UUID string, or a preset name.
    public static func resolve(
        _ reference: String,
        for identity: String,
        defaults: UserDefaults = Settings.defaults
    ) -> DisplayPreset? {
        if let id = UUID(uuidString: reference.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return preset(id: id, for: identity, defaults: defaults)
        }
        return preset(named: reference, for: identity, defaults: defaults)
    }

    // MARK: - Writing

    /// Insert or replace `preset` by id, preserving its position when it already
    /// exists and appending it otherwise.
    ///
    /// Refuses — and writes nothing — when the name is unusable (empty once
    /// trimmed) or when a *different* preset already uses it, so `apply <name>`
    /// can never be ambiguous.
    @discardableResult
    public static func save(
        _ preset: DisplayPreset,
        for identity: String,
        defaults: UserDefaults = Settings.defaults
    ) -> Bool {
        guard let name = sanitizedName(preset.name) else { return false }
        var list = stored(for: identity, defaults: defaults)
        if list.contains(where: { $0.id != preset.id && matchesName($0.name, name) }) {
            return false
        }
        var updated = preset
        updated.name = name
        if let index = list.firstIndex(where: { $0.id == preset.id }) {
            list[index] = updated
        } else {
            list.append(updated)
        }
        write(list, for: identity, defaults: defaults)
        return true
    }

    /// Remove the preset with `id`. Returns whether a preset was removed.
    @discardableResult
    public static func remove(
        id: UUID,
        for identity: String,
        defaults: UserDefaults = Settings.defaults
    ) -> Bool {
        var list = stored(for: identity, defaults: defaults)
        guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
        list.remove(at: index)
        write(list, for: identity, defaults: defaults)
        return true
    }

    // MARK: - Names

    /// A trimmed, length-capped name; nil when nothing usable remains.
    public static func sanitizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(DisplayPreset.maximumNameLength))
    }

    /// Whether two names are the same preset name: trimmed, case-insensitive.
    static func matchesName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(
                rhs.trimmingCharacters(in: .whitespacesAndNewlines),
                options: [.caseInsensitive]
            ) == .orderedSame
    }

    // MARK: - Storage

    private static func stored(for identity: String, defaults: UserDefaults) -> [DisplayPreset] {
        guard let data = defaults.data(forKey: defaultsKey(for: identity)),
              let list = try? JSONDecoder().decode([DisplayPreset].self, from: data) else {
            return []
        }
        return list
    }

    private static func write(_ list: [DisplayPreset], for identity: String, defaults: UserDefaults) {
        let key = defaultsKey(for: identity)
        guard !list.isEmpty else {
            // Drop the key entirely rather than storing "[]", so an identity
            // whose last preset was removed leaves no residue behind.
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Applying a preset is display work, so it lives beside the pure store rather
/// than in it: it narrows the preset's selection to what the display currently
/// exposes and hands the result to the one apply path,
/// `DisplayStateSnapshot.apply`.
@MainActor
public enum DisplayPresetApplier {
    /// Apply `preset` to `display`, returning what was applied and what the
    /// display no longer exposes.
    @discardableResult
    public static func apply(
        _ preset: DisplayPreset,
        to display: Display,
        resolution: ResolutionController,
        controller: any DisplayControlling
    ) -> DisplayPresetOutcome {
        let available = ProtectedProperties.available(for: display)
        let applied = preset.properties.intersection(available)
        let unavailable = preset.properties.subtracting(available)
        preset.state.apply(
            to: display,
            properties: applied,
            resolution: resolution,
            controller: controller
        )
        return DisplayPresetOutcome(requested: preset.properties, unavailable: unavailable)
    }
}

// MARK: - Settings accessors

/// Per-identity accessors, following the same shape as `ModeFavourites`' — a
/// thin front for `DisplayPresets`, so there is exactly one storage path.
extension Settings {
    /// Persisted display presets for `identity`, in saved order.
    public static func displayPresets(for identity: String) -> [DisplayPreset] {
        DisplayPresets.presets(for: identity)
    }

    /// Persist `preset` for `identity`; false when the name is unusable or
    /// already taken by another preset.
    @discardableResult
    public static func setDisplayPreset(_ preset: DisplayPreset, for identity: String) -> Bool {
        DisplayPresets.save(preset, for: identity)
    }

    /// Remove the preset with `id`; whether one was removed.
    @discardableResult
    public static func removeDisplayPreset(id: UUID, for identity: String) -> Bool {
        DisplayPresets.remove(id: id, for: identity)
    }
}
