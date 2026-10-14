import Foundation

/// Moves one display's stored settings onto another.
///
/// Per-display state is stored in two different shapes, and both have to be
/// handled — which is the trap this type exists to close:
///
/// - **Key prefixes**: one key per display per family, `<family>.<identity>`.
/// - **A shared blob with identity keys inside it**: `networkDeviceAttachments.v1`
///   is a single JSON object mapping identity to device name, so a transfer must
///   rewrite an entry rather than copy a key.
///
/// A transfer that only walked the prefixes would move everything except the
/// device attachment and look like it had worked.
public enum DisplaySettingsTransfer {
    /// Every per-display key family that is stored as a key prefix. Kept in one
    /// list so a transfer cannot silently miss a family, and asserted against the
    /// builders in `Settings`/`ModeFavourites` by `DisplaySettingsTransferTests`.
    public static let perIdentityKeyTemplates: [String] = [
        "edidOverride.%@",
        "cornerRadius.%@",
        "ddcFeatures.%@",
        "configProtection.v1.%@",
        "configProtection.properties.%@",
        "modeFavourites.%@",
    ]

    /// The shared blob whose keys are display identities.
    public static let sharedBlobFamily = "networkDeviceAttachments"

    public struct KeyMove: Equatable, Hashable {
        public let family: String
        public let source: String
        public let destination: String
    }

    /// Every key move a transfer would make, without touching anything.
    public static func keyMoves(from source: String, to destination: String) -> [KeyMove] {
        perIdentityKeyTemplates.map { template in
            KeyMove(
                family: template.replacingOccurrences(of: ".%@", with: ""),
                source: template.replacingOccurrences(of: "%@", with: source),
                destination: template.replacingOccurrences(of: "%@", with: destination)
            )
        }
    }

    public struct Outcome: Equatable {
        /// Families copied to the destination.
        public var moved: [String] = []
        /// Families the destination already had, left as they were.
        public var kept: [String] = []
        /// Whether the shared-blob attachment moved.
        public var movedDeviceAttachment = false

        public var isEmpty: Bool { moved.isEmpty && !movedDeviceAttachment }
    }

    /// Which families the display actually has stored.
    public static func familiesPresent(for identity: String, in defaults: UserDefaults = Settings.defaults) -> [String] {
        guard !identity.isEmpty else { return [] }
        var families = keyMoves(from: identity, to: identity)
            .filter { defaults.object(forKey: $0.source) != nil }
            .map { $0.family }
        if NetworkDeviceAttachment.attachments(defaults: defaults)[identity] != nil {
            families.append(sharedBlobFamily)
        }
        return families.sorted()
    }

    /// Copy `source`'s settings onto `destination`.
    ///
    /// Fail-closed at the destination: a family the destination already holds is
    /// left alone unless `overwrite` is set, so a transfer cannot quietly destroy
    /// settings the user has not moved off yet. Nothing is deleted from the
    /// source, which is what makes the operation reversible — the source keeps
    /// working, and `remove` clears it afterwards if that is what the user wants.
    @discardableResult
    public static func apply(
        from source: String,
        to destination: String,
        in defaults: UserDefaults = Settings.defaults,
        overwrite: Bool = false
    ) -> Outcome {
        var outcome = Outcome()
        guard !source.isEmpty, !destination.isEmpty, source != destination else { return outcome }

        for move in keyMoves(from: source, to: destination) {
            guard let value = defaults.object(forKey: move.source) else { continue }
            if !overwrite, defaults.object(forKey: move.destination) != nil {
                outcome.kept.append(move.family)
                continue
            }
            defaults.set(value, forKey: move.destination)
            outcome.moved.append(move.family)
        }

        if NetworkDeviceAttachment.move(
            from: source,
            to: destination,
            overwrite: overwrite,
            defaults: defaults
        ) {
            outcome.movedDeviceAttachment = true
        } else if NetworkDeviceAttachment.attachments(defaults: defaults)[source] != nil {
            outcome.kept.append(sharedBlobFamily)
        }
        return outcome
    }

    /// Remove everything stored for `identity`, including the shared-blob entry.
    ///
    /// This is the undo after a transfer, and the cleanup when changing the
    /// identity method orphans a key: the old key is still holding that display's
    /// settings, invisible to the app.
    @discardableResult
    public static func remove(for identity: String, in defaults: UserDefaults = Settings.defaults) -> Int {
        guard !identity.isEmpty else { return 0 }
        var removed = 0
        for move in keyMoves(from: identity, to: identity) where defaults.object(forKey: move.source) != nil {
            defaults.removeObject(forKey: move.source)
            removed += 1
        }
        if NetworkDeviceAttachment.attachments(defaults: defaults)[identity] != nil {
            // detach is the validated write path for this blob; it also refuses a
            // display that had none, which cannot happen here because we checked.
            if NetworkDeviceAttachment.detach(displayIdentityKey: identity, defaults: defaults) {
                removed += 1
            }
        }
        return removed
    }
}
