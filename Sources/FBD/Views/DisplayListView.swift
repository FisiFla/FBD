import FBDCore
import Foundation
import SwiftUI

/// Root view hosted in the status-item popover: display list with a header,
/// the Rosetta banner, and a settings panel.
@MainActor
struct DisplayListView: View {
    @State private var displays: [Display] = DisplayController.shared.displays
    @State private var showingSettings = false
    @State private var rosettaWarningVisible = DisplayListView.rosettaWarningActive

    // Tier 3: virtual screens & display groups. Controllers are held in @State
    // so their state survives across body evaluations (instantiating per
    // render would lose it); re-renders are driven by the ticks below.
    // Shared with AppCore and the HTTP API: one source of truth for
    // virtual screens (configs + active instances).
    @State private var virtualScreens = VirtualScreenController.shared
    @State private var groupsController = DisplayGroupsController()
    @State private var virtualScreensTick = 0
    @State private var groupItems: [DisplayGroup] = []

    // Virtual screen creation form.
    @State private var newScreenName = "Virtual Display"
    @State private var newScreenPreset = DisplayListView.resolutionPresets[0]
    @State private var newScreenRefresh = 60.0
    @State private var newScreenHDR = false
    @State private var isCreating = false
    @State private var createError: String?

    // Display group creation form.
    @State private var newGroupName = ""

    var body: some View {
        // NavigationStack provides the Settings push with a natural back
        // button; the window (NSPanel) owns sizing, so no fixed frame here.
        NavigationStack {
            mainContent
                .navigationTitle("FBD")
                .navigationDestination(isPresented: $showingSettings) {
                    SettingsView()
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                        .help("Settings")
                    }
                }
        }
        // Frosted glass behind the content — the panel window is transparent
        // (see StatusItemController) so this NSVisualEffectView provides the
        // Control Center-style blur and rounded corners.
        .background(FrostedBackground())
        .onReceive(NotificationCenter.default.publisher(for: .fbdDisplaysChanged)) { _ in
            displays = DisplayController.shared.displays
            virtualScreensTick += 1
            syncGroups()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fbdVirtualScreensChanged)) { _ in
            virtualScreensTick += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .fbdOpenSettings)) { _ in
            showingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .fbdRosettaWarningActive)) { _ in
            rosettaWarningVisible = true
        }
        .onAppear {
            syncGroups()
        }
    }

    // MARK: - Content

    /// The whole popover scrolls vertically; display rows are plain VStack
    /// entries (not a nested List) so nothing clips and row heights adapt.
    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 8) {
                header
                if rosettaWarningVisible {
                    RosettaWarningView()
                        .padding(.horizontal, 12)
                }
                Divider()
                    .opacity(0.5)
                if displays.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 8) {
                        ForEach(displays) { display in
                            DisplayRowView(display: display)
                                .padding(.horizontal, 12)
                        }
                    }
                }
                if virtualScreens.isAvailable {
                    virtualScreensSection
                }
                displayGroupsSection
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Brand tile.
            RoundedRectangle(cornerRadius: FBDTheme.radiusTile, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: "display")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text("FBD")
                    .font(.headline)
                Text("Free Better Display")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // In-content close for users who expect a button in the window
            // body; the title bar also has the standard close (×).
            Button {
                NotificationCenter.default.post(name: .fbdPanelCloseRequested, object: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close FBD panel")
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

    // MARK: - Virtual screens

    private var virtualScreensSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                createVirtualScreenRow

                if !virtualScreens.screens.isEmpty {
                    Divider()
                    activeVirtualScreens
                }

                if !pendingAutoConnectConfigs.isEmpty || !virtualScreens.screens.isEmpty {
                    HStack(spacing: 8) {
                        if !pendingAutoConnectConfigs.isEmpty {
                            Button("Reconnect all") {
                                virtualScreens.reconnectAuto()
                                virtualScreensTick += 1
                            }
                            .controlSize(.small)
                        }
                        if !virtualScreens.screens.isEmpty {
                            Button("Disconnect all") {
                                virtualScreens.disconnectAll()
                                virtualScreensTick += 1
                            }
                            .controlSize(.small)
                        }
                        Spacer(minLength: 0)
                    }
                }

                if let createError {
                    Text(createError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, 2)
        } label: {
            Label("Virtual Screens", systemImage: "rectangle.3.group")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: FBDTheme.radiusCard, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: FBDTheme.radiusCard, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    private var createVirtualScreenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Name", text: $newScreenName)
                    .textFieldStyle(.roundedBorder)
                Picker("Resolution", selection: $newScreenPreset) {
                    ForEach(DisplayListView.resolutionPresets) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 90, idealWidth: 120, maxWidth: .infinity)
                .controlSize(.small)
            }
            HStack(spacing: 8) {
                Stepper(value: $newScreenRefresh, in: 30...120, step: 10) {
                    Text("\(Int(newScreenRefresh)) Hz")
                        .monospacedDigit()
                }
                .controlSize(.small)
                Toggle("HDR", isOn: $newScreenHDR)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Spacer(minLength: 0)
                Button("Create") {
                    createVirtualScreen()
                }
                .controlSize(.small)
                .disabled(isCreating)
            }
        }
    }

    private var activeVirtualScreens: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(virtualScreens.screens) { screen in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(screen.config.name)
                            .font(.caption)
                            .lineLimit(1)
                        Text(activeScreenSubtitle(screen.config))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(String(format: "0x%X", screen.displayID))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Destroy") {
                        _ = virtualScreens.destroy(id: screen.id)
                        virtualScreensTick += 1
                    }
                    .controlSize(.mini)
                }
            }
        }
    }

    private var pendingAutoConnectConfigs: [VirtualScreenConfig] {
        virtualScreens.configs.filter { $0.autoConnect && !virtualScreens.isActive(id: $0.id) }
    }

    private func activeScreenSubtitle(_ config: VirtualScreenConfig) -> String {
        var label = "\(config.width)×\(config.height) · \(Int(config.refreshRate)) Hz"
        if config.isHDR { label += " · HDR" }
        return label
    }

    /// Create a virtual screen from the form. Hop off the runloop so the
    /// disabled "Create" state renders before the synchronous create call.
    private func createVirtualScreen() {
        guard !isCreating else { return }
        isCreating = true
        createError = nil
        let name = newScreenName.trimmingCharacters(in: .whitespaces)
        let config = VirtualScreenConfig(
            name: name.isEmpty ? "Virtual Display" : name,
            width: newScreenPreset.width,
            height: newScreenPreset.height,
            refreshRate: newScreenRefresh,
            isHDR: newScreenHDR,
            autoConnect: true
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if !virtualScreens.create(config) {
                createError = "Could not create virtual display."
            }
            isCreating = false
            virtualScreensTick += 1
        }
    }

    // MARK: - Display groups

    private var displayGroupsSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Group name", text: $newGroupName)
                        .textFieldStyle(.roundedBorder)
                    Button("New group") {
                        createGroup()
                    }
                    .controlSize(.small)
                    .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if groupItems.isEmpty {
                    Text("No groups yet. Create one to sync brightness or mirror displays.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(groupItems) { group in
                        groupRow(group)
                    }
                }
            }
            .padding(.top, 2)
        } label: {
            Label("Display Groups", systemImage: "square.grid.2x2")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: FBDTheme.radiusCard, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: FBDTheme.radiusCard, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    private func groupRow(_ group: DisplayGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(group.name)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(group.displayIDs.count) display\(group.displayIDs.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Mirror") {
                    _ = groupsController.mirror(inGroup: group.id)
                    syncGroups()
                }
                .controlSize(.mini)
                .disabled(group.displayIDs.count < 2)
                Button("Unmirror") {
                    _ = groupsController.unmirror(inGroup: group.id)
                    syncGroups()
                }
                .controlSize(.mini)
                Button(role: .destructive) {
                    groupsController.deleteGroup(id: group.id)
                    syncGroups()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
            }
            if !memberNames(for: group).isEmpty {
                Text(memberNames(for: group).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func memberNames(for group: DisplayGroup) -> [String] {
        group.displayIDs.compactMap { id in displays.first { $0.id == id }?.name }
    }

    private func createGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        groupsController.createGroup(name: name)
        newGroupName = ""
        syncGroups()
    }

    private func syncGroups() {
        groupItems = groupsController.groups
    }
}

// MARK: - Resolution presets

private extension DisplayListView {
    /// Built-in presets for the virtual-screen resolution picker.
    struct VirtualScreenPreset: Hashable, Identifiable {
        let width: UInt32
        let height: UInt32
        var id: String { label }
        var label: String { "\(width)×\(height)" }
    }

    static let resolutionPresets: [VirtualScreenPreset] = [
        VirtualScreenPreset(width: 1920, height: 1080),
        VirtualScreenPreset(width: 2560, height: 1440),
        VirtualScreenPreset(width: 3456, height: 2234),
        VirtualScreenPreset(width: 3840, height: 2160),
    ]
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when virtual screen state changes (created/destroyed/reconnected).
    /// VirtualScreenController currently posts `.fbdDisplaysChanged` after its
    /// mutations; this name lets future controller versions notify without
    /// touching the views.
    static let fbdVirtualScreensChanged = Notification.Name("FBDVirtualScreensChanged")
}
