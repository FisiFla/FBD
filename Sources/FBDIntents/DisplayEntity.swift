import AppIntents
import FBDCore

/// App Intents entity representing a display known to FBD.
///
/// Snapshots id/name/builtin-ness from the live `Display`; the current
/// brightness is the cached value only — a query must not run synchronous DDC
/// reads on the main actor.
///
/// Note: `@Property`-exposed entity metadata is intentionally not used here.
/// On this SDK the generic `EntityProperty.init(title:)` for Codable values
/// (String/Bool/Double…) is only available on macOS 26+, and the typed
/// macOS-13 overloads cover just Int/AttributedString/Date/entity values —
/// so the metadata is carried as plain stored properties to keep the entity
/// usable from macOS 13.
@available(macOS 13, *)
struct DisplayEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Display"

    static var defaultQuery = DisplayEntityQuery()

    /// Stable identifier: `Display.identityKey` (vendor/model/serial by default).
    /// The CGDirectDisplayID is reassigned across reboots and replugs, so a saved
    /// shortcut keyed on it would silently target the wrong display. Two identical
    /// monitors without serials share a key; resolution then picks the first online.
    var id: String

    /// Display name (e.g. "LG UltraFine").
    var name: String

    /// Whether this is the built-in display.
    var isBuiltin: Bool

    /// Last-known brightness 0…1, or nil when no control path exists.
    var currentBrightness: Double?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: isBuiltin ? "Built-in Display" : "External Display"
        )
    }

    init(id: String, name: String, isBuiltin: Bool, currentBrightness: Double?) {
        self.id = id
        self.name = name
        self.isBuiltin = isBuiltin
        self.currentBrightness = currentBrightness
    }

    /// Look up the live `Display` for this entity's id on the main actor.
    static func liveDisplay(id: String) async -> Display? {
        await MainActor.run { resolve(id: id) }
    }

    /// Resolve an entity id to a live display: by identity key first, then — for
    /// shortcuts saved when ids were raw CGDirectDisplayIDs — by numeric id.
    @MainActor
    static func resolve(id: String) -> Display? {
        let displays = DisplayController.shared.displays
        if let match = displays.first(where: { $0.isOnline && $0.identityKey == id })
            ?? displays.first(where: { $0.identityKey == id }) {
            return match
        }
        guard let numericID = UInt32(id) else { return nil }
        return DisplayController.shared.display(withID: numericID)
    }

    /// Snapshot from a live display. Main-actor only: touches `DisplayController`.
    @MainActor
    static func snapshot(from display: Display) -> DisplayEntity {
        DisplayEntity(
            id: display.identityKey,
            name: display.name,
            isBuiltin: display.isBuiltin,
            currentBrightness: display.brightness
        )
    }
}

/// Query backing `DisplayEntity`: resolves ids and enumerates all displays.
///
/// (This SDK no longer ships `DefaultQuery`; `EntityQuery` + a
/// `suggestedEntities()` override provides the same "pick from all displays"
/// behavior on macOS 13.)
@available(macOS 13, *)
struct DisplayEntityQuery: EntityQuery {
    func entities(for identifiers: [DisplayEntity.ID]) async throws -> [DisplayEntity] {
        await MainActor.run {
            identifiers.compactMap { DisplayEntity.resolve(id: $0).map(DisplayEntity.snapshot(from:)) }
        }
    }

    func suggestedEntities() async throws -> [DisplayEntity] {
        try await allEntities()
    }

    /// All currently connected displays.
    func allEntities() async throws -> [DisplayEntity] {
        await MainActor.run {
            DisplayController.shared.displays.map { DisplayEntity.snapshot(from: $0) }
        }
    }
}
