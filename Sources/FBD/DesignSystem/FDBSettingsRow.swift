import SwiftUI

/// Labelled settings rows for the Settings pages.
///
/// These live in the design system rather than in `SettingsPages.swift` because
/// every settings page uses them and their shape — label, value, then a caption
/// explaining the setting — is what makes the long panes scannable. Keeping the
/// shape in one place is what stops a second page from inventing its own
/// spacing and caption styling.

/// A labelled control with an optional explanatory caption underneath.
struct SettingsRow<Content: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: FBDTheme.spacingM) {
                Text(title)
                Spacer(minLength: 8)
                content()
                    // The title is drawn beside the control, so without this the
                    // control itself carries no label and VoiceOver announces a
                    // bare checkbox or slider with no idea what it changes.
                    .accessibilityLabel(title)
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A slider that shows its label and current value inline. BetterDisplay's
/// settings surface shows label + value for every slider; this is that shape.
struct SettingsSliderRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let caption: String?
    let onChange: (Double) -> Void

    var body: some View {
        // The slider sits on the title line rather than on its own line below it.
        // It has to: a Form row here is handed a fixed ~37pt regardless of its
        // content (verified — pinning the slider's height changed nothing at all,
        // and the app was confirmed to be running the changed code), while a
        // three-line row (title 16 + slider 20 + caption 13 + gaps) needs 53pt.
        // The caption below was therefore drawn on top of the *next* row's title.
        // This shape matches `SettingsRow` — label left, control right — which is
        // why every other row in Settings was already fine.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: FBDTheme.spacingM) {
                Text(title)
                Slider(value: Binding(get: { value }, set: onChange), in: range)
                    // The label and the value are siblings of the slider, so both
                    // have to be attached for VoiceOver to say what the slider
                    // controls and where it currently sits.
                    .accessibilityLabel(title)
                    .accessibilityValue(format(value))
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
