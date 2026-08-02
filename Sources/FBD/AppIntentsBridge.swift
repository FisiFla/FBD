import AppIntents
import FBDIntents

/// App-side declaration that exposes the FBDIntents module's Shortcuts
/// actions. AppIntents discovers cross-module packages through this
/// conformance; without it the intents compile but never appear in
/// Shortcuts.
///
/// NOTE: runtime discovery cannot be verified in CI — verify once on a
/// machine with Shortcuts: `shortcuts list` should show the FBD actions
/// after installing the app.
@available(macOS 14, *)
public struct FBDAppIntentsBridge: AppIntentsPackage {
    public init() {}

    public static var includedPackages: [any AppIntentsPackage.Type] {
        [FBDAppIntents.self]
    }
}
