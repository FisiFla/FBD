import SwiftUI

/// The popover's one row: icon chip · title · optional value · optional chevron/checkmark.
/// Whole row is the hit target; hover highlight like a native menu.
struct FBDListRow: View {
    let symbol: String
    let title: LocalizedStringKey
    var value: String? = nil
    var showsChevron = false
    var isChecked = false
    var role: ButtonRole? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: FBDTheme.spacingL) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                    .frame(width: FBDTheme.chipSize, height: FBDTheme.chipSize)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                Text(title)
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
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}
