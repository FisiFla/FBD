import SwiftUI

/// The popover's one row: icon chip · title · optional value · optional chevron/checkmark.
/// Whole row is the hit target; hover highlight like a native menu.
struct FBDListRow: View {
    let symbol: String
    let title: Text
    var value: String? = nil
    var showsChevron = false
    var isChecked = false
    var role: ButtonRole? = nil
    let action: (() -> Void)?

    @State private var isHovering = false

    init(
        symbol: String, title: LocalizedStringKey, value: String? = nil, showsChevron: Bool = false,
        isChecked: Bool = false, role: ButtonRole? = nil, action: @escaping () -> Void
    ) {
        self.symbol = symbol; self.title = Text(title); self.value = value
        self.showsChevron = showsChevron; self.isChecked = isChecked; self.role = role
        self.action = action
    }

    /// For user-provided titles (names), rendered verbatim. A nil `action` makes a
    /// non-interactive row: same content, no button, no hover highlight.
    init(
        symbol: String, verbatim title: String, value: String? = nil, showsChevron: Bool = false,
        isChecked: Bool = false, role: ButtonRole? = nil, action: (() -> Void)? = nil
    ) {
        self.symbol = symbol; self.title = Text(verbatim: title); self.value = value
        self.showsChevron = showsChevron; self.isChecked = isChecked; self.role = role
        self.action = action
    }

    static func isInteractive(action: (() -> Void)?) -> Bool { action != nil }

    @ViewBuilder
    var body: some View {
        if let action {
            Button(role: role, action: action) { content }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .accessibilityAddTraits(isChecked ? .isSelected : [])
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    private var content: some View {
            HStack(spacing: FBDTheme.spacingL) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                    .frame(width: FBDTheme.chipSize, height: FBDTheme.chipSize)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                title
                    .font(.system(size: 13))
                    .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                Spacer(minLength: FBDTheme.spacingM)
                if let value {
                    Text(value).font(FBDTheme.Font.secondary).foregroundStyle(.secondary)
                }
                if isChecked {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                if showsChevron {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, FBDTheme.spacingM)
            .frame(height: FBDTheme.rowHeight)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: FBDTheme.radiusTile)
                    .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
            )
    }
}
