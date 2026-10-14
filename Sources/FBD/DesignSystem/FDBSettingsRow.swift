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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: FBDTheme.spacingM) {
                Text(title)
                Spacer(minLength: 8)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: onChange), in: range)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
