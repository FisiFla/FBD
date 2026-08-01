import AppIntents

// FBDIntents — App Intents (Tier 5): Shortcuts actions for FBD.

/// App Intents package exposing FBD's Shortcuts actions.
///
/// Public so the app target can wire it up centrally (via the app's own
/// package/registration — there is deliberately no `@main` here).
///
/// Note: this SDK's `AppIntentsPackage` no longer has a `body: some Intents`
/// requirement — packages expose the `AppIntent` conformances of their module
/// and may list sub-packages via `includedPackages`. The intents themselves
/// are the five types in `DisplayIntents.swift`.
@available(macOS 14, *)
public struct FBDAppIntents: AppIntentsPackage {
    public init() {}

    /// No sub-packages; all FBD intents live in this module.
    public static var includedPackages: [any AppIntentsPackage.Type] { [] }
}
