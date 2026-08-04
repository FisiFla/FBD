import AppKit
import CoreGraphics
import FBDCore
import SwiftUI

/// Full per-display control page for the Settings → Per-Display tab.
/// Reuses the popover card's building blocks (brightness slider, options
/// menu, filters, DDC panel, disclosure sections) in a roomier layout, plus
/// the connect/disconnect action and the offline state.
@MainActor
struct PerDisplayCardView: View {
    @ObservedObject var display: Display

    /// Confirmation for the soft-disconnect action — shared by the header
    /// button (which carries the confirmation dialog) and the options menu.
    @State private var confirmingDisable = false
    /// Bumped when .fbdDisplayUpdated fires for this display to re-render.
    @State private var refreshTick = 0
    /// Bumped by the refresh handler so the DDC panel re-reads monitor state.
    @State private var ddcRefreshRequest = 0
    /// Bumped by the refresh handler so the XDR section re-syncs the upscale
    /// slider with the display's effective target.
    @State private var xdrSyncRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if display.isOnline {
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
            } else {
                Text("Display is offline — connect it to control it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var header: some View {
        HStack(spacing: 8) {
            Text(display.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(display.isOnline ? "online" : "offline")
                .font(.caption2)
                .foregroundStyle(display.isOnline ? .green : .secondary)
            if let mode = display.currentMode, !mode.label.isEmpty {
                Text("\(mode.label)\(mode.refreshLabel.isEmpty ? "" : " · \(mode.refreshLabel)")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                .help(display.isOnline ? "Disable display" : "Re-enable display")
                .accessibilityLabel(display.isOnline ? "Disable display" : "Re-enable display")
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
}
