import AppKit
import CoreGraphics
import FBDCore
import SwiftUI

/// Per-display card: icon tile + name + capability tags, a nits-aware
/// brightness slider, and per-capability child views — the options menu,
/// screen filters, DDC/CI controls and the disclosure sections — each owning
/// its own @State. This view only orchestrates: header, brightness, section
/// ordering and the shared `.fbdDisplayUpdated` refresh wiring.
@MainActor
struct DisplayRowView: View {
    @ObservedObject var display: Display

    /// Bumped when .fbdDisplayUpdated fires for this display to re-render.
    @State private var refreshTick = 0
    /// Confirmation for the soft-disconnect action — shared by the header
    /// power button (which carries the confirmation dialog) and the options
    /// menu's "Manage Display" item.
    @State private var confirmingDisable = false
    /// Bumped by the refresh handler so the DDC panel re-reads monitor state.
    @State private var ddcRefreshRequest = 0
    /// Bumped by the refresh handler so the XDR section re-syncs the upscale
    /// slider with the display's effective target.
    @State private var xdrSyncRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            BrightnessSliderView(display: display)
            disclosureSection(icon: "slider.horizontal.3", title: "Filters") {
                FilterControlsView(display: display)
            }
            if display.ddcAvailable {
                DDCPanelView(display: display, refreshRequest: ddcRefreshRequest)
            }
            DisplaySectionsView(
                display: display,
                refreshTick: $refreshTick,
                xdrSyncRequest: xdrSyncRequest
            )
            disableRow
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
        .onReceive(NotificationCenter.default.publisher(for: .fbdDisplayUpdated)) { note in
            if let id = note.userInfo?["displayID"] as? CGDirectDisplayID, id == display.id {
                refreshTick += 1
                ddcRefreshRequest += 1
                xdrSyncRequest += 1
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            // Display-kind tile.
            RoundedRectangle(cornerRadius: FBDTheme.radiusTile, style: .continuous)
                .fill(kind.tint.opacity(0.16))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: kind.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(kind.tint)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(display.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    capabilityTags
                }
                if !resolutionLabel.isEmpty {
                    Text(resolutionLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)

            // Options menu (ellipsis) — the single entry point for the
            // per-display submenus and quick toggles.
            DisplayOptionsMenuView(
                display: display,
                confirmingDisable: $confirmingDisable,
                refreshTick: $refreshTick
            )

            // Soft-disconnect power button (gated by the connect/disconnect setting).
            if Settings.enableDisconnectOption {
                Button {
                    confirmingDisable = true
                } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(display.isOnline ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            .help(display.isOnline ? "Disable display" : "Display offline")
            .accessibilityLabel(display.isOnline ? "Disable display" : "Re-enable display")
            .accessibilityHint("Display will go dark until re-enabled")
            .confirmationDialog(
                "Disable display?",
                isPresented: $confirmingDisable,
                titleVisibility: .visible
            ) {
                Button("Disable", role: .destructive) {
                    _ = DisconnectController().setEnabled(false, displayID: display.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Display will go dark until re-enabled.")
            }
            }
        }
    }

    private var kind: DisplayKind { DisplayKind(display: display) }

    @ViewBuilder
    private var capabilityTags: some View {
        HStack(spacing: 4) {
            FBDTag(text: kind.label, tint: kind.tint)
            if display.ddcAvailable {
                FBDTag(text: "DDC", tint: .teal)
            }
            if display.isXDRCapable {
                FBDTag(text: "XDR", tint: .orange)
            } else if display.isHDRModeCapable {
                FBDTag(text: "HDR", tint: .orange)
            }
        }
        .layoutPriority(1)
    }

    private var resolutionLabel: String {
        guard let mode = display.currentMode else { return "" }
        var label = mode.label
        if !mode.refreshLabel.isEmpty {
            label += " · \(mode.refreshLabel)"
        }
        return label
    }

    // MARK: - Disable / re-enable

    private var disableRow: some View {
        Group {
            if !display.isOnline {
                Button {
                    _ = DisconnectController().setEnabled(true, displayID: display.id)
                } label: {
                    Label("Re-enable display", systemImage: "power")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.blue)
                .controlSize(.small)
            }
        }
    }
}
