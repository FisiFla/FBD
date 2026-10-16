import FBDCore
import SwiftUI

@MainActor
struct AboutSettingsPage: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: FBDTheme.radiusTile, style: .continuous)
                        .fill(Color.accentColor.gradient)
                        .frame(width: 34, height: 34)
                        .overlay(
                            Image(systemName: "display")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("FBD — Free Better Display")
                            .font(.callout.weight(.medium))
                        Text("Version \(versionString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Link("GitHub — FisiFla/FBD", destination: URL(string: "https://github.com/FisiFla/FBD")!)
            } header: {
                Label("About", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
    }

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}
