import FBDCore
import SwiftUI

/// Every mode the display offers, as one flat checkmark list — the page behind the display
/// page's curated "Show All N Modes" row.
struct AllModesPage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var display: Display

    var body: some View {
        // Offered modes, not the raw list: "Allow unsafe modes" governs what is listed here too.
        let modes = display.offeredModes
        VStack(alignment: .leading, spacing: 0) {
            if modes.isEmpty {
                Text("No modes available")
                    .font(FBDTheme.Font.secondary)
                    .foregroundStyle(.secondary)
            }
            ForEach(modes, id: \.self) { mode in
                FBDListRow(
                    symbol: "rectangle",
                    verbatim: mode.label,
                    value: detail(mode),
                    isChecked: mode == display.currentMode
                ) {
                    DisplayController.shared.applyMode(mode, to: display)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "60 Hz · HiDPI": the two things that tell same-size modes apart.
    private func detail(_ mode: DisplayMode) -> String? {
        var parts: [String] = []
        if mode.refreshRate > 0 { parts.append(ModeListLogic.rateLabel(mode.refreshRate)) }
        if mode.isHiDPI { parts.append(String(localized: "HiDPI")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
