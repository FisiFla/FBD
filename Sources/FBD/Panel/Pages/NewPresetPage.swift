import FBDCore
import SwiftUI

struct NewPresetPage: View {
    @ObservedObject var model: PanelModel
    let display: Display

    @State private var name = ""
    @State private var symbol = DisplayPresetSymbol.default
    private let resolution = ResolutionController()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: FBDTheme.spacingM), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: FBDTheme.spacingL) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            LazyVGrid(columns: columns, spacing: FBDTheme.spacingM) {
                ForEach(DisplayPresetSymbol.allCases, id: \.self) { option in
                    Button { symbol = option } label: {
                        Image(systemName: option.symbolName)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 32, height: 32)
                            .modifier(SelectedGlass(isSelected: option == symbol))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: option.label))
                    .accessibilityAddTraits(option == symbol ? .isSelected : [])
                }
            }
            Button("Save", action: save)
                .fbdGlassButton()
                .disabled(Self.validatedName(name) == nil)
        }
        .padding(.horizontal, FBDTheme.spacingM)
    }

    /// Same name rules as the save path (`DisplayPresets.sanitizedName`): trimmed, length-capped,
    /// nil when nothing usable remains.
    static func validatedName(_ raw: String) -> String? {
        DisplayPresets.sanitizedName(raw)
    }

    /// Builds the preset exactly like the Settings page does: the picked symbol, the default
    /// property set, and a snapshot of the display as it is now.
    private func save() {
        guard let name = Self.validatedName(name) else { return }
        let preset = DisplayPreset(
            name: name,
            symbol: symbol,
            properties: DisplayPresets.defaultProperties,
            state: DisplayStateSnapshot.capture(
                for: display,
                resolution: resolution,
                controller: DisplayController.shared
            )
        )
        guard DisplayPresets.save(preset, for: display.identityKey) else {
            FBDNotice.shared.report(String(localized: "A preset named '\(name)' already exists."))
            return
        }
        model.open(.home)
        FBDNotice.shared.report(String(localized: "Saved '\(name)'."))
    }
}

/// Selected = accent-tinted glass circle; otherwise a faint plain circle.
private struct SelectedGlass: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content.fbdGlass(in: Circle(), tint: .accentColor)
        } else {
            content.background(Circle().fill(Color.primary.opacity(0.08)))
        }
    }
}
