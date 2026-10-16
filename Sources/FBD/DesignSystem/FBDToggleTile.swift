import SwiftUI

/// Control Center–style round toggle: glass circle, label, On/Off.
struct FBDToggleTile: View {
    let symbol: String
    let title: LocalizedStringKey
    let isOn: Bool
    var isEnabled = true
    var disabledReason: LocalizedStringKey? = nil
    let action: () -> Void

    /// English key for the state label; rendered through `LocalizedStringKey`.
    static func stateText(isOn: Bool, isEnabled: Bool) -> String {
        guard isEnabled else { return "Unavailable" }
        return isOn ? "On" : "Off"
    }

    private var stateKey: LocalizedStringKey {
        LocalizedStringKey(Self.stateText(isOn: isOn, isEnabled: isEnabled))
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: FBDTheme.spacingXS) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .frame(width: FBDTheme.tileSize, height: FBDTheme.tileSize)
                    .fbdGlass(in: Circle(), tint: isOn ? Color.accentColor : nil, interactive: isEnabled)
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(stateKey)
                    .font(FBDTheme.Font.secondary).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(disabledReason.map { Text($0) } ?? Text(title))
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(stateKey))
    }
}
