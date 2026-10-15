import AppIntents
import FBDCore

/// App Intents package exposing FBD's Shortcuts actions.
///
/// Public so the app target can wire it up centrally (via the app's own
/// AppIntentsBridge). There is deliberately no `@main` here — the package
/// just declares this module's `AppIntent` conformances for discovery.
/// (This SDK's `AppIntentsPackage` exposes the module's intents without a
/// `body`; `includedPackages` stays empty because there are no sub-packages.)
@available(macOS 14, *)
public struct FBDAppIntents: AppIntentsPackage {
    public init() {}

    /// No sub-packages; all FBD intents live in this module.
    public static var includedPackages: [any AppIntentsPackage.Type] { [] }
}

/// Errors surfaced to Shortcuts when an intent cannot complete.
@available(macOS 13, *)
enum DisplayIntentError: LocalizedError {
    case displayNotFound
    case invalidValue(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            return "The display could not be found. It may have been disconnected."
        case .invalidValue(let message):
            return message
        case .operationFailed(let reason):
            return "The operation failed: \(reason)"
        }
    }
}

// MARK: - Set brightness

/// Sets the brightness of a display, 0 (minimum) to 1 (maximum).
@available(macOS 13, *)
struct SetDisplayBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Display Brightness"
    static var description: IntentDescription? = IntentDescription("Sets the brightness of a display from 0 to 1 (0% to 100%).")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Set brightness of \(\.$display) to \(\.$brightness)")
    }

    @Parameter(title: "Display", description: "The display to adjust.")
    var display: DisplayEntity

    @Parameter(title: "Brightness", description: "Brightness from 0 (minimum) to 1 (maximum).", default: 0.5)
    var brightness: Double

    func perform() async throws -> some IntentResult {
        guard brightness.isFinite, (0...1).contains(brightness) else {
            throw DisplayIntentError.invalidValue("Brightness must be between 0 and 1.")
        }
        guard let target = await DisplayEntity.liveDisplay(id: display.id) else {
            throw DisplayIntentError.displayNotFound
        }
        let succeeded = await MainActor.run {
            DisplayController.shared.setBrightness(brightness, on: target)
        }
        guard succeeded else {
            throw DisplayIntentError.operationFailed("no brightness control path exists for this display.")
        }
        return .result()
    }
}

// MARK: - Get brightness

/// Reads the current brightness of a display (0 to 1).
@available(macOS 13, *)
struct GetDisplayBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Display Brightness"
    static var description: IntentDescription? = IntentDescription("Gets the current brightness of a display, from 0 to 1.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Get brightness of \(\.$display)")
    }

    @Parameter(title: "Display", description: "The display to read.")
    var display: DisplayEntity

    func perform() async throws -> some IntentResult {
        guard let target = await DisplayEntity.liveDisplay(id: display.id) else {
            throw DisplayIntentError.displayNotFound
        }
        let value = await MainActor.run {
            DisplayController.shared.getBrightness(for: target)
        }
        return .result(value: value ?? 0)
    }
}

// MARK: - Set volume

/// Sets the speaker volume of a display over DDC/CI, 0 (muted) to 1 (maximum).
@available(macOS 13, *)
struct SetDisplayVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Display Volume"
    static var description: IntentDescription? = IntentDescription("Sets the speaker volume of a display over DDC/CI, from 0 to 1.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Set volume of \(\.$display) to \(\.$volume)")
    }

    @Parameter(title: "Display", description: "The display to adjust.")
    var display: DisplayEntity

    @Parameter(title: "Volume", description: "Volume from 0 (muted) to 1 (maximum).", default: 0.5)
    var volume: Double

    func perform() async throws -> some IntentResult {
        guard volume.isFinite, (0...1).contains(volume) else {
            throw DisplayIntentError.invalidValue("Volume must be between 0 and 1.")
        }
        guard let target = await DisplayEntity.liveDisplay(id: display.id) else {
            throw DisplayIntentError.displayNotFound
        }
        let succeeded = await MainActor.run {
            DisplayController.shared.setVolume(volume, on: target)
        }
        guard succeeded else {
            throw DisplayIntentError.operationFailed("this display does not support DDC/CI volume control.")
        }
        return .result()
    }
}

// MARK: - List displays

/// Lists the names of all displays currently connected to this Mac.
@available(macOS 13, *)
struct ListDisplaysIntent: AppIntent {
    static var title: LocalizedStringResource = "List Displays"
    static var description: IntentDescription? = IntentDescription("Lists the displays currently connected to this Mac.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        let names = await MainActor.run {
            DisplayController.shared.displays.map(\.name)
        }
        let summary = names.isEmpty ? "No displays found." : names.joined(separator: ", ")
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

// MARK: - Enable XDR upscaling

/// Raises the native XDR upscaling target of an Apple XDR display.
@available(macOS 13, *)
struct EnableXDRUpscalingIntent: AppIntent {
    static var title: LocalizedStringResource = "Enable XDR Upscaling"
    static var description: IntentDescription? = IntentDescription("Raises the native XDR upscaling target of an Apple XDR display.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Enable XDR upscaling on \(\.$display) at \(\.$nits) nits")
    }

    @Parameter(title: "Display", description: "The display to upscale.")
    var display: DisplayEntity

    @Parameter(title: "Target Nits", description: "Upscale target in nits.", default: 1600)
    var nits: Int

    func perform() async throws -> some IntentResult {
        guard nits > 0 else {
            throw DisplayIntentError.invalidValue("The upscaling target must be greater than 0 nits.")
        }
        guard let target = await DisplayEntity.liveDisplay(id: display.id) else {
            throw DisplayIntentError.displayNotFound
        }
        let succeeded = await MainActor.run {
            DisplayController.shared.setXDRUpscaleTarget(nits, on: target)
        }
        guard succeeded else {
            throw DisplayIntentError.operationFailed("this display does not support XDR upscaling.")
        }
        return .result()
    }
}

// MARK: - Lock dim

/// Dims the display while the screen is locked or the screen saver runs.
@available(macOS 13, *)
struct SetLockDimIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Lock Dim"
    static var description: IntentDescription? = IntentDescription("Dims the display while the screen is locked or the screen saver is running.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Set lock dim \(\.$enabled) at \(\.$targetPercent)%")
    }

    @Parameter(title: "Enabled", description: "Whether to dim while locked.", default: true)
    var enabled: Bool

    @Parameter(title: "Target", description: "Brightness percentage to dim to: 0 is fully dark, 100 is no dim at all.", default: 10)
    var targetPercent: Double

    func perform() async throws -> some IntentResult {
        guard targetPercent.isFinite, (0...100).contains(targetPercent) else {
            throw DisplayIntentError.invalidValue("The target must be a percentage between 0 and 100.")
        }
        // `clamped()` is the same normalisation the app, the CLI and the HTTP API
        // apply, so a value reaching Settings is always in range.
        let policy = LockDimPolicy(enabled: enabled, targetPercent: targetPercent).clamped()
        await MainActor.run {
            Settings.lockDimEnabled = policy.enabled
            Settings.lockDimTargetPercent = policy.targetPercent
        }
        return .result(value: Int(policy.targetPercent))
    }
}

// MARK: - Keyboard control target

/// Chooses which screen the brightness and volume keys act on.
@available(macOS 13, *)
struct SetKeyboardControlTargetIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Keyboard Control Target"
    static var description: IntentDescription? = IntentDescription("Chooses which screen the brightness and volume keys act on.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Set the keyboard control target to \(\.$target)")
    }

    /// A `String` rather than an `AppEnum`: declaring the enum conformance
    /// outside the module that owns `KeyboardControlTarget` would be a
    /// retroactive conformance. Validated against the real cases instead, so the
    /// error can name them.
    @Parameter(title: "Target", description: "mouseScreen, focusedScreen, allSuitableScreens or audioDeviceMatch.")
    var target: String

    func perform() async throws -> some IntentResult {
        let raw = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolved = KeyboardControlTarget(rawValue: raw) else {
            let allowed = KeyboardControlTarget.allCases.map(\.rawValue).joined(separator: ", ")
            throw DisplayIntentError.invalidValue("Unknown target '\(raw)'. Valid targets: \(allowed).")
        }
        await MainActor.run { Settings.keyboardControlTarget = resolved }
        return .result(value: resolved.rawValue)
    }
}

// MARK: - Group sync

/// Propagates one member's brightness to the rest of a display group, the same
/// operation as the Settings page's "Sync now".
@available(macOS 13, *)
struct SyncDisplayGroupIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Display Group"
    static var description: IntentDescription? = IntentDescription("Syncs a display group's brightness, propagating the first connected member's value to the rest.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Sync display group \(\.$groupName)")
    }

    @Parameter(title: "Group", description: "The name of the display group to sync.")
    var groupName: String

    func perform() async throws -> some IntentResult {
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DisplayIntentError.invalidValue("A display group name is required.")
        }
        // Resolve the group first so an unknown name is reported as such rather
        // than as a group with nothing to sync.
        let groupID = await MainActor.run { DisplayGroupsController().group(named: name)?.id }
        guard let groupID else {
            throw DisplayIntentError.invalidValue("No display group is named '\(name)'.")
        }

        let written = await MainActor.run { () -> Int? in
            let controller = DisplayController.shared
            let groups = DisplayGroupsController()
            let displays = controller.displays
            // Read each member's brightness once, up front, so the closure the
            // controller receives is a plain lookup and no DDC read happens off
            // the hot path.
            var brightnessByID: [UInt32: Double] = [:]
            for display in displays {
                if let value = display.brightness ?? controller.getBrightness(for: display) {
                    brightnessByID[display.id] = value
                }
            }
            guard let reading = groups.syncValue(
                inGroup: groupID,
                connectedIDs: Set(displays.map { $0.id }),
                currentBrightness: { brightnessByID[$0] }
            ) else {
                return nil
            }
            return groups.applyGroupSync(
                reading.value,
                inGroup: groupID,
                controller: controller,
                referenceDisplayID: reading.sourceDisplayID
            )
        }
        guard let written else {
            throw DisplayIntentError.operationFailed("the group has no connected member with a readable brightness.")
        }
        return .result(value: written)
    }
}

// MARK: - Display presets

/// Applies one of a display's named presets — the same operation as the Presets
/// section in Settings, so "set the desk up for work" becomes one Shortcuts
/// action.
@available(macOS 13, *)
struct ApplyDisplayPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Display Preset"
    static var description: IntentDescription? = IntentDescription("Applies a named preset to a display, restoring the configuration the preset recorded.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Apply preset \(\.$preset) to \(\.$display)")
    }

    @Parameter(title: "Preset", description: "The name of the preset to apply.")
    var preset: String

    @Parameter(title: "Display", description: "The display the preset belongs to.")
    var display: DisplayEntity

    func perform() async throws -> some IntentResult {
        let name = preset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DisplayIntentError.invalidValue("A preset name is required.")
        }
        guard let target = await DisplayEntity.liveDisplay(id: display.id) else {
            throw DisplayIntentError.displayNotFound
        }
        // Resolve the preset before applying it, so an unknown name is reported
        // as unknown rather than as a preset that quietly changed nothing.
        let resolved = await MainActor.run {
            DisplayPresets.preset(named: name, for: target.identityKey)
        }
        guard let preset = resolved else {
            throw DisplayIntentError.invalidValue("No preset is named '\(name)' on this display.")
        }

        let outcome = await MainActor.run {
            DisplayPresetApplier.apply(
                preset,
                to: target,
                resolution: ResolutionController(),
                controller: DisplayController.shared
            )
        }
        guard !outcome.applied.isEmpty || outcome.requested.isEmpty else {
            throw DisplayIntentError.operationFailed("no part of '\(preset.name)' applies to this display.")
        }
        return .result(dialog: IntentDialog(stringLiteral: "Applied preset '\(preset.name)'."))
    }
}
