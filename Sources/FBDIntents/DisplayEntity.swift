import AppIntents
import FBDCore

/// App Intents entity representing a display known to FBD.
///
/// Snapshots id/name/builtin-ness from the live `Display`; the current
/// brightness is captured at query time (cached value first, live read only
/// when the cache is empty).
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

    /// Stable identifier: the CGDirectDisplayID as a string.
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
        await MainActor.run {
            guard let numericID = UInt32(id) else { return nil }
            return DisplayController.shared.display(withID: numericID)
        }
    }

    /// Snapshot from a live display. Main-actor only: touches `DisplayController`.
    @MainActor
    static func snapshot(from display: Display) -> DisplayEntity {
        DisplayEntity(
            id: String(display.id),
            name: display.name,
            isBuiltin: display.isBuiltin,
            currentBrightness: display.brightness ?? DisplayController.shared.getBrightness(for: display)
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
        let wanted = Set(identifiers)
        return await MainActor.run {
            DisplayController.shared.displays
                .filter { wanted.contains(String($0.id)) }
                .map { DisplayEntity.snapshot(from: $0) }
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
