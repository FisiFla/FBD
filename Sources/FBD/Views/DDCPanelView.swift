import FBDCore
import SwiftUI

/// DDC/CI panel: contrast / volume / mute / input source + a capabilities
/// read. Owns the last-sent DDC values (send-only controls have no readable
/// state on Display yet — the local values keep the controls interactive)
/// and re-reads the monitor's real state when the row's refresh handler
/// fires.
@MainActor
struct DDCPanelView: View {
    @ObservedObject var display: Display
    /// Bumped by DisplayRowView's `.fbdDisplayUpdated` handler; any change
    /// here triggers a DDC read-back.
    let refreshRequest: Int

    // Send-only DDC controls have no readable state on Display yet — keep the
    // last sent value locally so the controls stay interactive.
    // Nil until the monitor answers a read: the slider then shows "—" rather than a made-up 50%.
    @State private var contrast: Double?
    @State private var volume: Double?
    /// Trailing-debounce work items for the contrast / volume writes, keyed by row label.
    @State private var pendingWrites: [String: DispatchWorkItem] = [:]
    @State private var muted = false
    @State private var inputSource = ""
    /// The input we last set from the named menu, for immediate feedback. The next DDC refresh
    /// replaces it with what the display actually reports — see `currentInput`.
    @State private var selectedInput: UInt16?
    /// What the display reports as its current input, when it answers. Rides in the same batched
    /// read as contrast/volume/mute, so marking the current input costs no extra DDC traffic; nil
    /// means the display did not answer, which many do for VCP 0x60.
    @State private var currentInput: UInt16?
    /// Outcome of the last explicit action in this panel. Nil until the user does
    /// something — the panel does not narrate its own background refreshes.
    @State private var status: FBDStatus?

    var body: some View {
        ddcPanel
            .onAppear { refreshDDCState() }
            .onChange(of: refreshRequest) { _ in
                refreshDDCState()
            }
    }

    /// Pull the monitor's real contrast / volume / mute / input state into the UI.
    /// Falls back to the last sent value when the monitor doesn't answer
    /// (some DDC monitors ignore reads).
    private func refreshDDCState() {
        guard display.ddcAvailable else { return }
        // The reads used to run here on the main actor, one per value, each doing
        // its own `queue.sync`. They now happen together on the display's queue and
        // arrive back on the main actor.
        DisplayController.shared.readDDCState(for: display) { state in
            if let value = state.contrast { contrast = value }
            if let value = state.volume { volume = value }
            if let value = state.muted { muted = value }
            if let value = state.inputSource {
                currentInput = DDC.inputSource(from: value)
            }
        }
    }

    /// The input to mark as current: what the display reports, else the last one we set. The
    /// fallback keeps the menu honest between the write and the read-back, and stops it claiming
    /// knowledge when the display never answers.
    private var effectiveInput: UInt16? {
        currentInput ?? selectedInput
    }

    private var ddcPanel: some View {
        VStack(alignment: .leading, spacing: FBDTheme.spacingM) {
            sliderRow(label: "Contrast", accessibilityLabel: String(localized: "Contrast for \(display.name)"), value: Binding(
                get: { contrast },
                set: { contrast = $0 }
            )) { DisplayController.shared.setContrast($0, on: display) }

            sliderRow(label: "Volume", accessibilityLabel: String(localized: "Volume for \(display.name)"), value: Binding(
                get: { volume },
                set: { volume = $0 }
            )) { DisplayController.shared.setVolume($0, on: display) }

            Toggle("Mute", isOn: Binding(
                get: { muted },
                set: { muted = $0; DisplayController.shared.setMuted($0, on: display) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(FBDTheme.Font.secondary)
            .accessibilityLabel("Mute \(display.name)")

            // Named inputs, when the display has told us which ones it has. A checkmark list
            // with the input in effect marked: the read rides in the same batched DDC refresh
            // as contrast/volume, so marking it costs nothing extra, and when the display does
            // not answer the checkmark falls back to the last one set rather than inventing one.
            if !inputOptions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Input")
                        .font(FBDTheme.Font.secondary)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, FBDTheme.spacingXS)
                    ForEach(inputOptions, id: \.self) { value in
                        FBDListRow(
                            symbol: "rectangle.connected.to.line.below",
                            title: LocalizedStringKey(inputLabel(value)),
                            isChecked: value == effectiveInput
                        ) {
                            setInput(value)
                        }
                    }
                }
                .help("Switch the display's input (VCP 0x60)")
            } else {
                Text("Read capabilities to list this display's inputs by name.")
                    .font(FBDTheme.Font.secondary)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: FBDTheme.spacingM) {
                TextField("Input", text: $inputSource)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 50, idealWidth: 70, maxWidth: 90)
                    .help("DDC input source (VCP 0x60), 1–15")
                    .accessibilityLabel("Input source for \(display.name)")
                Button("Apply") {
                    applyInputSource()
                }
                .controlSize(.small)
                // Disabled rather than silently doing nothing: `applyInputSource`
                // used to `guard ... else { return }`, so a typo produced no
                // feedback at all.
                .disabled(parsedInputSource == nil)
                .help("Manual override: a raw DDC input source (VCP 0x60) between 1 and 15")
                Spacer(minLength: 0)
            }

            FBDListRow(symbol: "doc.text.magnifyingglass", title: "Read capabilities") {
                readCapabilities()
            }
            .help("Query the display's supported VCP features (VCP 0xF3)")
            // Disabled while the probe is in flight, so it cannot be queued twice.
            .disabled(isProbing)

            if let status {
                FBDStatusLine(status: status)
            }
        }
    }

    private func sliderRow(
        label: LocalizedStringResource,
        accessibilityLabel: String,
        value: Binding<Double?>,
        send: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: FBDTheme.spacingM) {
            Text(label)
                .font(FBDTheme.Font.secondary)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            FDBSlider(
                value: Binding(
                    get: { value.wrappedValue ?? 0.5 },
                    set: { value.wrappedValue = $0; scheduleWrite(String(localized: label), $0, send) }
                ),
                in: 0...1,
                accessibilityLabel: accessibilityLabel,
                valueText: { "\(Int(($0 * 100).rounded()))%" },
                // The default sun glyphs mean brightness; the row's label already names the value.
                endSymbols: nil
            )
            Text(value.wrappedValue.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(FBDTheme.Font.secondary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    /// Trailing-debounced DDC write: the slider drags at ~60 Hz and every DDC write is a slow I2C
    /// transaction, so only the value the drag settles on (the release value) is sent.
    private func scheduleWrite(_ key: String, _ newValue: Double, _ send: @escaping (Double) -> Void) {
        pendingWrites[key]?.cancel()
        let workItem = DispatchWorkItem {
            Task { @MainActor in send(newValue) }
        }
        pendingWrites[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: workItem)
    }

    /// The entered VCP 0x60 value, or nil when the field holds no usable one.
    /// Drives the Apply button's disabled state so the field cannot be submitted
    /// into a no-op.
    private var parsedInputSource: UInt16? {
        let trimmed = inputSource.trimmingCharacters(in: .whitespaces)
        guard let value = UInt16(trimmed), value > 0 else { return nil }
        return value
    }

    private func applyInputSource() {
        guard let value = parsedInputSource else { return }
        setInput(value)
    }

    /// The inputs this display reports for VCP 0x60, taken from its capabilities
    /// reply. Empty until a capabilities read has happened, and empty for a
    /// display that lists the code without a value set — in which case the raw
    /// field is the only honest way to set it.
    private var inputOptions: [UInt16] {
        guard let raw = display.ddcCapabilities?.raw else { return [] }
        return DDC.capabilityValues(for: DDC.VCPCode.inputSource.rawValue, in: raw)
    }

    /// Known MCCS name for an input value, else the raw number. Vendors disagree
    /// on the standard numbering, so an unnamed value is shown as itself rather
    /// than given a plausible-looking wrong label.
    private func inputLabel(_ value: UInt16) -> String {
        DDC.inputSourceName(for: value) ?? String(format: "Input 0x%02X", value)
    }

    private func setInput(_ value: UInt16) {
        let accepted = DisplayController.shared.setInputSource(value, on: display)
        if accepted {
            selectedInput = value
            status = .succeeded(String(localized: "Input set to \(inputLabel(value))"))
        } else {
            status = .failed(String(localized: "The display did not accept that write"))
        }
    }

    /// True while the capabilities probe is in flight.
    private var isProbing: Bool {
        if case .working = status { return true }
        return false
    }

    /// Probe the monitor's VCP 0xF3 capabilities.
    ///
    /// Genuinely asynchronous now, so the spinner actually renders: the read
    /// sleeps for the DDC settle interval and does up to three I2C reads, and it
    /// used to do all of that on the main actor.
    private func readCapabilities() {
        status = .working(String(localized: "Reading capabilities…"))
        DisplayController.shared.readCapabilities(for: display) { answered in
            status = answered
                ? .succeeded(String(localized: "Capabilities read"))
                : .failed(String(localized: "No reply from the display"))
        }
    }
}
