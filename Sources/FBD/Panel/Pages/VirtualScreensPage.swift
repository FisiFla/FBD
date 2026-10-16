import FBDCore
import SwiftUI

struct VirtualScreensPage: View {
    @ObservedObject var model: PanelModel

    // `VirtualScreenController` is a plain class; `tick` forces a re-read after changes.
    private let controller = VirtualScreenController.shared
    @State private var tick = 0

    @State private var showsCreateForm = false
    @State private var newName = "Virtual Display"
    @State private var newPreset = VirtualScreensPage.resolutionPresets[0]
    @State private var newRefresh = 60.0
    @State private var newHDR = false
    @State private var isCreating = false
    @State private var createError: String?

    @State private var confirmingDisconnectAll = false
    @State private var pendingDestroy: VirtualScreenInstance?

    var body: some View {
        Group {
            if controller.isAvailable {
                content
            } else {
                Text("Virtual screens aren't available on this Mac")
                    .font(FBDTheme.Font.secondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(FBDTheme.spacingXL)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fbdVirtualScreensChanged)) { _ in changed() }
    }

    private var content: some View {
        let _ = tick  // dependency: re-evaluate after a mutation
        return VStack(alignment: .leading, spacing: FBDTheme.spacingXS) {
            ForEach(controller.screens) { screen in
                HStack(spacing: FBDTheme.spacingS) {
                    FBDListRow(
                        symbol: "rectangle.on.rectangle",
                        verbatim: screen.config.name,
                        value: Self.subtitle(screen.config)
                    )
                    Button { pendingDestroy = screen } label: { Image(systemName: "trash") }
                        .fbdGlassButton()
                        .controlSize(.small)
                        .accessibilityLabel("Destroy")
                }
            }
            ForEach(inactiveConfigs) { config in
                HStack(spacing: FBDTheme.spacingS) {
                    FBDListRow(
                        symbol: "rectangle.on.rectangle",
                        verbatim: config.name,
                        value: Self.subtitle(config)
                    )
                    Button("Reconnect") {
                        if !controller.reconnect(id: config.id) {
                            createError = String(localized: "Could not create virtual display.")
                        }
                        changed()
                    }
                    .fbdGlassButton()
                    .controlSize(.small)
                }
            }
            FBDListRow(
                symbol: "plus", title: "New Virtual Screen",
                showsChevron: !showsCreateForm
            ) { withAnimation(FBDTheme.animationFast) { showsCreateForm.toggle() } }
            if showsCreateForm { createForm }
            if let createError {
                Text(createError)
                    .font(FBDTheme.Font.secondary)
                    .foregroundStyle(.red)
                    .padding(.horizontal, FBDTheme.spacingM)
            }
            if !controller.screens.isEmpty {
                FBDListRow(symbol: "eject", title: "Disconnect All", role: .destructive) {
                    confirmingDisconnectAll = true
                }
            }
        }
        .fbdConfirmation(
            "Disconnect all virtual screens?",
            isPresented: $confirmingDisconnectAll,
            confirm: "Disconnect All"
        ) {
            controller.disconnectAll()
            changed()
        }
        .fbdConfirmation(
            "Destroy this virtual screen?",
            isPresented: Binding(
                get: { pendingDestroy != nil },
                set: { if !$0 { pendingDestroy = nil } }
            ),
            confirm: "Destroy",
            message: "The virtual screen is removed until you create it again."
        ) {
            if let screen = pendingDestroy { _ = controller.destroy(id: screen.id) }
            pendingDestroy = nil
            changed()
        }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: FBDTheme.spacingS) {
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
            ForEach(Self.resolutionPresets) { preset in
                FBDListRow(
                    symbol: "aspectratio", verbatim: preset.label,
                    isChecked: preset == newPreset
                ) { newPreset = preset }
            }
            HStack(spacing: FBDTheme.spacingM) {
                Stepper(value: $newRefresh, in: 30...120, step: 10) {
                    Text("\(Int(newRefresh)) Hz").monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Refresh rate")
                .accessibilityValue("\(Int(newRefresh)) hertz")
                .controlSize(.small)
                Toggle("HDR", isOn: $newHDR)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Spacer(minLength: 0)
                Button("Create", action: create)
                    .fbdGlassButton()
                    .controlSize(.small)
                    .disabled(isCreating)
            }
        }
        .padding(.horizontal, FBDTheme.spacingM)
    }

    private var inactiveConfigs: [VirtualScreenConfig] {
        controller.configs.filter { !controller.isActive(id: $0.id) }
    }

    private func changed() {
        tick += 1
        model.refreshCounts()
    }

    /// Hop off the runloop so the disabled "Create" state renders before the
    /// synchronous create call (as the pre-revamp form did).
    private func create() {
        guard !isCreating else { return }
        isCreating = true
        createError = nil
        let name = newName.trimmingCharacters(in: .whitespaces)
        let config = VirtualScreenConfig(
            name: name.isEmpty ? "Virtual Display" : name,
            width: newPreset.width,
            height: newPreset.height,
            refreshRate: newRefresh,
            isHDR: newHDR,
            autoConnect: true
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if controller.create(config) {
                showsCreateForm = false
            } else {
                createError = String(localized: "Could not create virtual display.")
            }
            isCreating = false
            changed()
        }
    }

    static func subtitle(_ config: VirtualScreenConfig) -> String {
        var label = "\(config.width)×\(config.height) · \(Int(config.refreshRate)) Hz"
        if config.isHDR { label += " · HDR" }
        return label
    }
}

// MARK: - Resolution presets

extension VirtualScreensPage {
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
