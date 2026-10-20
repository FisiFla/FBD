import AppIntents
import FBDCore

// MARK: - HDR mode

/// Turns HDR mode on or off for a display.
@available(macOS 13, *)
struct SetDisplayHDRModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Display HDR Mode"
    static var description: IntentDescription? = IntentDescription("Turns HDR mode on or off for a display.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Set HDR mode of \(\.$display) to \(\.$enabled)")
    }

    @Parameter(title: "Display", description: "The display to adjust.")
    var display: DisplayEntity

    @Parameter(title: "Enabled", description: "Turn HDR mode on (true) or off (false).", default: true)
    var enabled: Bool

    func perform() async throws -> some IntentResult {
        guard let target = await DisplayEntity.liveDisplay(id: display.id) else {
            throw DisplayIntentError.displayNotFound
        }
        let succeeded = await MainActor.run {
            DisplayController.shared.setHDRMode(enabled, on: target)
        }
        guard succeeded else {
            throw DisplayIntentError.operationFailed(String(localized: "this display does not support HDR mode."))
        }
        return .result()
    }
}

// MARK: - Extra brightness

/// Sets the extra-brightness target of a display, in nits.
@available(macOS 13, *)
struct SetDisplayExtraBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Display Extra Brightness"
    static var description: IntentDescription? = IntentDescription("Sets the extra-brightness target of a display, in nits.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Set extra brightness of \(\.$display) to \(\.$nits) nits")
    }

    @Parameter(title: "Display", description: "The display to adjust.")
    var display: DisplayEntity

    @Parameter(title: "Nits", description: "The brightness target in nits.", default: 800)
    var nits: Int

    func perform() async throws -> some IntentResult {
        guard nits > 0 else {
            throw DisplayIntentError.invalidValue(String(localized: "The brightness target must be a positive number of nits."))
        }
        guard let target = await DisplayEntity.liveDisplay(id: display.id) else {
            throw DisplayIntentError.displayNotFound
        }
        let succeeded = await MainActor.run {
            DisplayController.shared.setXDRUpscaleTarget(nits, on: target)
        }
        guard succeeded else {
            throw DisplayIntentError.operationFailed(String(localized: "this display cannot be driven that bright."))
        }
        return .result()
    }
}

// MARK: - Input source

/// Switches a display to another input source (DDC/CI).
@available(macOS 13, *)
struct SwitchDisplayInputIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Display Input"
    static var description: IntentDescription? = IntentDescription("Switches a display to another input source over DDC/CI.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Switch input of \(\.$display) to \(\.$source)")
    }

    @Parameter(title: "Display", description: "The display to switch.")
    var display: DisplayEntity

    @Parameter(title: "Source", description: "The input source number, as reported by the display.", default: 1)
    var source: Int

    func perform() async throws -> some IntentResult {
        guard source >= 0, source <= Int(UInt16.max) else {
            throw DisplayIntentError.invalidValue(String(localized: "The input source number is out of range."))
        }
        guard let target = await DisplayEntity.liveDisplay(id: display.id) else {
            throw DisplayIntentError.displayNotFound
        }
        let succeeded = await MainActor.run {
            DisplayController.shared.setInputSource(UInt16(source), on: target)
        }
        guard succeeded else {
            throw DisplayIntentError.operationFailed(String(localized: "this display does not support input switching."))
        }
        return .result()
    }
}

// MARK: - Connect / disconnect

/// Connects or disconnects a display, optionally remembering the choice.
@available(macOS 13, *)
struct SetDisplayConnectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect or Disconnect Display"
    static var description: IntentDescription? = IntentDescription("Connects or disconnects a display. A remembered disconnect is re-applied when the display is plugged in again.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$display) connected to \(\.$connected)")
    }

    @Parameter(title: "Display", description: "The display to connect or disconnect.")
    var display: DisplayEntity

    @Parameter(title: "Connected", description: "Connect the display (true) or disconnect it (false).", default: true)
    var connected: Bool

    @Parameter(title: "Remember", description: "Remember the disconnect, so it is re-applied after a replug.", default: false)
    var remember: Bool

    func perform() async throws -> some IntentResult {
        guard let target = await DisplayEntity.liveDisplay(id: display.id) else {
            throw DisplayIntentError.displayNotFound
        }
        let succeeded = await MainActor.run {
            DisplayController.shared.setDisplayConnected(connected, remember: remember, for: target)
        }
        guard succeeded else {
            throw DisplayIntentError.operationFailed(String(localized: "the display could not be switched."))
        }
        return .result()
    }
}

// MARK: - Image adjustment

/// Applies an image adjustment (contrast, saturation, gamma, temperature) to a display.
@available(macOS 13, *)
struct ApplyDisplayImageAdjustmentIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Display Image Adjustment"
    static var description: IntentDescription? = IntentDescription("Applies an image adjustment to a display: contrast, saturation, gamma and temperature.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Adjust \(\.$display): contrast \(\.$contrast), saturation \(\.$saturation), gamma \(\.$gamma), temperature \(\.$temperature)")
    }

    @Parameter(title: "Display", description: "The display to adjust.")
    var display: DisplayEntity

    @Parameter(title: "Contrast", description: "Contrast, 0.5 to 1.5 (1 leaves it unchanged).", default: 1)
    var contrast: Double

    @Parameter(title: "Saturation", description: "Saturation, 0 to 2 (1 leaves it unchanged).", default: 1)
    var saturation: Double

    @Parameter(title: "Gamma", description: "Gamma, 0.2 to 3 (1 leaves it unchanged).", default: 1)
    var gamma: Double

    @Parameter(title: "Temperature", description: "Temperature, 0 to 1 (0.5 leaves it unchanged).", default: 0.5)
    var temperature: Double

    func perform() async throws -> some IntentResult {
        guard contrast.isFinite, saturation.isFinite, gamma.isFinite, temperature.isFinite else {
            throw DisplayIntentError.invalidValue(String(localized: "The adjustment values must be numbers."))
        }
        guard let target = await DisplayEntity.liveDisplay(id: display.id) else {
            throw DisplayIntentError.displayNotFound
        }
        let params = ScreenFilterParams(
            brightness: 1,
            contrast: contrast,
            saturation: saturation,
            gamma: gamma,
            temperature: temperature
        )
        let succeeded = await MainActor.run {
            DisplayController.shared.setScreenFilter(params, on: target)
        }
        guard succeeded else {
            throw DisplayIntentError.operationFailed(String(localized: "the image adjustment could not be applied."))
        }
        return .result()
    }
}
