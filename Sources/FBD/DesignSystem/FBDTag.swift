import SwiftUI

/// Small capsule badge (DDC / XDR / Built-in / Virtual…). Tint + label only —
/// color never carries meaning alone, so the label keeps it accessible.
struct FBDTag: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.14)))
            .accessibilityLabel(text)
    }
}
