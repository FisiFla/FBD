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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // One continuous top bar per page: the traffic-light zone (the
            // first 28pt, where the window server draws the buttons) shares
            // the same material as the header content, so the buttons sit ON
            // the bar instead of floating above it.
            if showingSettings {
                settingsTopBar
                    .transition(reduceMotion ? .opacity : .opacity)
            } else {
                mainTopBar
                    .transition(reduceMotion ? .opacity : .opacity)
            }

            Group {
                if showingSettings {
                    SettingsView()
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                } else {
                    mainContent
                        .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                }
            }
        }
        // Frosted glass behind the content — the panel window is transparent
        // (see StatusItemController) so this NSVisualEffectView provides the
        // Control Center-style blur and rounded corners.
        .background(FrostedBackground())
        // The panel uses .fullSizeContentView; ignore the titlebar safe-area
        // inset so the top bar actually extends up under the traffic lights
        // (without this the whole bar is pushed ~28pt down, recreating the
        // gap between the buttons and the content).
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .fbdDisplaysChanged)) { _ in
            displays = DisplayController.shared.displays
            virtualScreensTick += 1
            syncGroups()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fbdVirtualScreensChanged)) { _ in
            virtualScreensTick += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .fbdOpenSettings)) { _ in
            withAnimation(reduceMotion ? nil : FBDTheme.animationSpring) {
                showingSettings = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fbdSettingsClosed)) { _ in
            withAnimation(reduceMotion ? nil : FBDTheme.animationSpring) {
                showingSettings = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fbdRosettaWarningActive)) { _ in
            rosettaWarningVisible = true
        }
        .onAppear {
            syncGroups()
        }
    }

    /// Open settings: the window resize is driven by StatusItemController,
    /// which observes .fbdOpenSettings.
    private func openSettings() {
        NotificationCenter.default.post(name: .fbdOpenSettings, object: nil)
    }

    // MARK: - Content

    /// The whole popover scrolls vertically; display rows are plain VStack
    /// entries (not a nested List) so nothing clips and row heights adapt.
    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 8) {
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

    /// Main-page top bar: one unified row — the traffic lights (drawn by the
    /// window server in the first ~64pt) and the brand/actions share the same
    /// band, so there is no empty gap under the buttons.
    private var mainTopBar: some View {
        VStack(spacing: 0) {
            // Traffic-light band: the window server draws the buttons here
            // (~12pt circles centered 14pt from the top). The brand row sits
            // directly below with tight spacing — no empty gap.
            Color.clear
                .frame(height: 22)
                .accessibilityHidden(true)

            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: FBDTheme.radiusTile, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: "display")
                            .font(.system(size: 11, weight: .semibold))
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

                Spacer(minLength: 4)

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Settings")
                .help("Settings")

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
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    /// Settings top bar: same unified row — lights + back + title + close.
    private var settingsTopBar: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 22)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                Button {
                    NotificationCenter.default.post(name: .fbdSettingsClosed, object: nil)
                } label: {
                    Label("FBD", systemImage: "chevron.left")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back to FBD")
                .help("Back")

                Text("Settings")
                    .font(.headline)

                Spacer(minLength: 4)

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
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
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
