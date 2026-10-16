import SwiftUI

/// A switch with its label leading and the switch at the trailing edge. A `.switch` toggle outside
/// a `Form` sits right after its label; these toggles are shared by the popover (no `Form`) and
/// Settings (a `Form`), so they lay themselves out the same way in both.
struct FBDTrailingSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: FBDTheme.spacingM) {
            // Read once, by the switch below: VoiceOver would otherwise say the label twice.
            configuration.label
                .accessibilityHidden(true)
            Spacer(minLength: FBDTheme.spacingM)
            // The label is kept (visually hidden) so VoiceOver still names the switch.
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

extension ToggleStyle where Self == FBDTrailingSwitchStyle {
    static var fbdTrailingSwitch: FBDTrailingSwitchStyle { FBDTrailingSwitchStyle() }
}
