import AppIntents

/// Ready-made Shortcuts / Siri phrases for the most common FBD actions.
///
/// Every phrase must contain the application name. Intents with a required
/// display parameter ask for it when invoked, so they need no parameterised phrase.
@available(macOS 13, *)
struct FBDShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetDisplayBrightnessIntent(),
            phrases: [
                "Set display brightness with \(.applicationName)",
                "Change brightness in \(.applicationName)",
            ],
            shortTitle: "Set Display Brightness",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: ListDisplaysIntent(),
            phrases: ["List displays in \(.applicationName)"],
            shortTitle: "List Displays",
            systemImageName: "display.2"
        )
        AppShortcut(
            intent: SetLockDimIntent(),
            phrases: ["Dim displays when locked with \(.applicationName)"],
            shortTitle: "Set Lock Dim",
            systemImageName: "lock.display"
        )
    }
}
