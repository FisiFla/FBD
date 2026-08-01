import AppIntents
import FBDCore

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
