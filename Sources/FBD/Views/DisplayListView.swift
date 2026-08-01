import FBDCore
import SwiftUI

/// Root view hosted in the status-item popover: display list with a header,
/// the Rosetta banner, and a settings panel.
@MainActor
struct DisplayListView: View {
    @State private var displays: [Display] = DisplayController.shared.displays
    @State private var showingSettings = false
    @State private var rosettaWarningVisible = DisplayListView.rosettaWarningActive

    var body: some View {
        Group {
            if showingSettings {
                SettingsView(onDone: { showingSettings = false })
            } else {
                mainContent
            }
        }
        .frame(width: 380)
        .onReceive(NotificationCenter.default.publisher(for: .fbdDisplaysChanged)) { _ in
            displays = DisplayController.shared.displays
        }
        .onReceive(NotificationCenter.default.publisher(for: .fbdOpenSettings)) { _ in
            showingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .fbdRosettaWarningActive)) { _ in
            rosettaWarningVisible = true
        }
    }

    // MARK: - Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            header
            if rosettaWarningVisible {
                RosettaWarningView()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider()
            if displays.isEmpty {
                emptyState
            } else {
                List(displays) { display in
                    DisplayRowView(display: display)
                }
                .listStyle(.plain)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("FBD")
                .font(.headline)
            Text("Free Better Display")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "display")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No displays")
                .font(.headline)
            Text("Connect a display to control it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 32)
    }

    /// Whether the Rosetta warning banner applies to this process.
    private static var rosettaWarningActive: Bool {
        IOAVServiceAPI.isAppleSilicon && IOAVServiceAPI.isRunningUnderRosetta && Settings.showRosettaWarning
    }
}
