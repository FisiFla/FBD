import SwiftUI

/// Banner shown in the menu header when FBD runs under Rosetta 2 on Apple
/// Silicon (DDC/CI is unavailable in that configuration).
struct RosettaWarningView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("DDC control is unavailable under Rosetta — run FBD natively (arm64) for full functionality.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}
