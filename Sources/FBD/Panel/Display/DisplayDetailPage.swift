import CoreGraphics
import FBDCore
import SwiftUI

/// One display's page: resolution, refresh rate, XDR / HDR, color profile, EDID, filters,
/// monitor controls and display actions, each a section header over flat checkmark rows.
/// The per-display views (`DisplaySectionsView`, `FilterControlsView`, `DDCPanelView`) are the
/// same ones Settings → Displays embeds; this page only orders them and adds the mode lists.
struct DisplayDetailPage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var display: Display

    /// Bumped when `.fbdDisplayUpdated` fires for this display — the same refresh wiring the
    /// Settings card uses, so the DDC panel re-reads and the XDR slider re-syncs.
    @State private var refreshTick = 0
    @State private var ddcRefreshRequest = 0
    @State private var xdrSyncRequest = 0
    @State private var confirmingDisable = false

    var body: some View {
        VStack(alignment: .leading, spacing: FBDTheme.spacingL) {
            if display.isOnline {
                if !display.offeredModes.isEmpty {
                    resolutionSection
                }
                if !refreshRates.isEmpty {
                    refreshRateSection
                }
                DisplaySectionsView(
                    display: display,
                    refreshTick: $refreshTick,
                    xdrSyncRequest: xdrSyncRequest,
                    showsResolutions: false
                )
                section("Filters") {
                    FilterControlsView(display: display)
                }
                section("Monitor Controls") {
                    if display.ddcAvailable {
                        DDCPanelView(display: display, refreshRequest: ddcRefreshRequest)
                    } else {
                        Text("Monitor controls unavailable — no DDC/CI")
                            .font(FBDTheme.Font.secondary)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("Display is offline — connect it to control it.")
                    .font(FBDTheme.Font.secondary)
                    .foregroundStyle(.secondary)
            }
            displaySection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fbdDisableDisplayConfirmation(isPresented: $confirmingDisable, display: display)
        .onReceive(NotificationCenter.default.publisher(for: .fbdDisplayUpdated)) { note in
            if let id = note.userInfo?["displayID"] as? CGDirectDisplayID, id == display.id {
                refreshTick += 1
                ddcRefreshRequest += 1
                xdrSyncRequest += 1
            }
        }
    }

    private func section<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: FBDTheme.spacingXS) {
            DetailSectionHeader(title: title)
            content()
        }
    }

    // MARK: - Resolution

    private var resolutionSection: some View {
        section("Resolution") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ModeListLogic.curated(modes: display.offeredModes, current: display.currentMode), id: \.self) { mode in
                    FBDListRow(
                        symbol: "rectangle",
                        title: LocalizedStringKey(mode.label),
                        value: mode.isHiDPI ? String(localized: "HiDPI") : nil,
                        isChecked: mode == display.currentMode
                    ) {
                        DisplayController.shared.applyMode(mode, to: display)
                    }
                }
                FBDListRow(
                    symbol: "list.bullet",
                    title: "Show All \(display.offeredModes.count) Modes",
                    showsChevron: true
                ) {
                    model.open(.allModes(display.id))
                }
                .accessibilityIdentifier("display.allModes")
            }
        }
    }

    // MARK: - Refresh rate

    private var refreshRates: [Double] {
        ModeListLogic.refreshRates(modes: display.offeredModes, current: display.currentMode)
    }

    private var refreshRateSection: some View {
        section("Refresh Rate") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(refreshRates, id: \.self) { hz in
                    FBDListRow(
                        symbol: "speedometer",
                        title: LocalizedStringKey(ModeListLogic.rateLabel(hz)),
                        isChecked: hz == display.currentMode?.refreshRate
                    ) {
                        if let mode = ModeListLogic.mode(
                            refreshRate: hz, modes: display.offeredModes, current: display.currentMode
                        ) {
                            DisplayController.shared.applyMode(mode, to: display)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Display actions

    private var isMain: Bool { CGDisplayIsMain(display.id) != 0 }

    /// The current rotation in degrees (CoreGraphics reports 0, 90, 180 or 270).
    private var rotation: Int { Int(CGDisplayRotation(display.id).rounded()) }

    @ViewBuilder
    private var displaySection: some View {
        let showsMain = display.isOnline && !isMain
        let showsRotation = display.isOnline && !display.isBuiltin
        let showsPower = !display.isOnline || Settings.enableDisconnectOption
        if showsMain || showsRotation || showsPower {
            section("Display") {
                VStack(alignment: .leading, spacing: 0) {
                    if showsMain {
                        FBDListRow(symbol: "menubar.rectangle", title: "Make Main Display") {
                            _ = DisplayController.shared.setAsMainDisplay(display)
                        }
                    }
                    if showsRotation {
                        Text("Rotation")
                            .font(FBDTheme.Font.secondary)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, FBDTheme.spacingXS)
                        ForEach([0, 90, 180, 270], id: \.self) { angle in
                            FBDListRow(symbol: "rotate.right", title: "\(angle)°", isChecked: rotation == angle) {
                                // Rotation genuinely fails on displays that do not support it, so
                                // the refusal is reported rather than discarded.
                                if DisplayController.shared.setRotation(angle, on: display) == nil {
                                    FBDNotice.shared.report(String(localized: "This display would not rotate to \(angle)°."))
                                }
                            }
                        }
                    }
                    if display.isOnline {
                        if Settings.enableDisconnectOption {
                            FBDListRow(symbol: "power", title: "Disconnect", role: .destructive) {
                                confirmingDisable = true
                            }
                        }
                    } else {
                        FBDListRow(symbol: "power", title: "Re-enable display") {
                            _ = DisconnectController().setEnabled(true, displayID: display.id)
                        }
                    }
                }
            }
        }
    }
}

/// Section title. File-private stand-in for Task 5's `SectionHeader` (same body), which is not
/// on this branch.
private struct DetailSectionHeader: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title).font(FBDTheme.Font.sectionHeader).foregroundStyle(.secondary)
    }
}
