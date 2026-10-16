import FBDCore
import SwiftUI

/// The display page's presets and "More" sections: everything the pre-revamp popover's per-display
/// ⋯ menu offered that the page's other sections do not — HiDPI, Auto Brightness, resolution
/// favourites, mirroring, Picture in Picture / streaming and Show in Settings — as list rows,
/// so each is on this page (the second click from the popover). Lists that pick a target
/// (favourite slots, mirror and stream targets) expand inline, as the virtual-screen form does,
/// rather than opening a menu from the non-activating popover.
struct DisplayMoreSection: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var display: Display

    private enum Expanded { case favourites, mirror, stream }
    @State private var expanded: Expanded?
    /// `PipStreamController` and the favourites store are not observable; bumped after a change.
    @State private var tick = 0
    @State private var resolution = ResolutionController()

    var body: some View {
        let _ = tick  // dependency: re-evaluate after a non-observable change
        VStack(alignment: .leading, spacing: FBDTheme.spacingL) {
            presetsSection
            TitledSection("More") {
                VStack(alignment: .leading, spacing: 0) {
                    if display.isOnline { onlineRows }
                    FBDListRow(symbol: "gearshape", title: "Show in Settings") {
                        DisplayOptionActions.showInSettings(display)
                    }
                    .accessibilityIdentifier("display.showInSettings")
                }
            }
        }
    }

    // MARK: - Presets

    private var presetsSection: some View {
        TitledSection("Presets") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.presets(for: display)) { preset in
                    FBDListRow(symbol: preset.symbol.symbolName, verbatim: preset.name) {
                        model.apply(preset, to: display)
                    }
                }
                FBDListRow(symbol: "plus", title: "New Preset…") { model.open(.newPreset(display.id)) }
            }
        }
    }

    // MARK: - More

    @ViewBuilder
    private var onlineRows: some View {
        if DisplayOptionActions.hiDPICounterpart(of: display) != nil {
            let isHiDPI = display.currentMode?.isHiDPI ?? false
            FBDListRow(symbol: "textformat.size", title: "HiDPI", isChecked: isHiDPI) {
                DisplayOptionActions.setHiDPI(!isHiDPI, on: display)
            }
        }
        if let autoBrightness = DisplayOptionActions.autoBrightness(of: display) {
            FBDListRow(symbol: "sun.max.circle", title: "Auto Brightness", isChecked: autoBrightness) {
                DisplayOptionActions.setAutoBrightness(!autoBrightness, on: display)
                tick += 1
            }
        }

        expander(.favourites, symbol: "star", title: "Resolution Favourites")
        if expanded == .favourites { favouriteRows }

        let targets = DisplayOptionActions.mirrorTargets(for: display)
        let mirrored = DisplayOptionActions.isMirrored(display)
        if !targets.isEmpty || mirrored {
            expander(.mirror, symbol: "rectangle.on.rectangle", title: "Mirror Display")
            if expanded == .mirror {
                if mirrored {
                    FBDListRow(symbol: "rectangle.split.2x1", title: "Unmirror") {
                        DisplayOptionActions.unmirror(display)
                    }
                }
                ForEach(targets) { target in
                    FBDListRow(symbol: "display", verbatim: target.name) {
                        DisplayOptionActions.mirror(display, onto: target)
                    }
                }
            }
        }

        FBDListRow(symbol: "pip", title: "Picture in Picture") {
            DisplayOptionActions.startPictureInPicture(of: display)
            tick += 1
        }
        if !targets.isEmpty {
            expander(.stream, symbol: "play.rectangle", title: "Stream to")
            if expanded == .stream {
                ForEach(targets) { target in
                    FBDListRow(symbol: "display", verbatim: target.name) {
                        DisplayOptionActions.stream(display, to: target)
                        tick += 1
                    }
                }
            }
        }
        if PipStreamController.shared.isActive {
            FBDListRow(symbol: "stop.circle", title: "Stop PiP / Stream") {
                PipStreamController.shared.stop()
                tick += 1
            }
        }
    }

    /// A row that shows or hides the rows beneath it; the chevron is hidden while open.
    private func expander(_ which: Expanded, symbol: String, title: LocalizedStringKey) -> some View {
        FBDListRow(symbol: symbol, title: title, showsChevron: expanded != which) {
            withAnimation(FBDTheme.animationFast) { expanded = expanded == which ? nil : which }
        }
    }

    /// Five recall slots: tapping a recorded slot applies it; the trailing button records the
    /// current mode into it.
    private var favouriteRows: some View {
        ForEach(1...ModeFavourites.slotCount, id: \.self) { slot in
            let favourite = ModeFavourites.favourite(slot: slot, for: display.identityKey)
            HStack(spacing: FBDTheme.spacingS) {
                if let favourite {
                    FBDListRow(
                        symbol: "\(slot).circle",
                        verbatim: DisplayOptionActions.favouriteSummary(favourite)
                    ) {
                        DisplayOptionActions.applyFavourite(slot, to: display, using: resolution)
                    }
                } else {
                    FBDListRow(symbol: "\(slot).circle", verbatim: String(localized: "empty"))
                }
                Button("Record") {
                    if DisplayOptionActions.recordFavourite(slot, for: display, using: resolution) {
                        tick += 1
                    }
                }
                .fbdGlassButton()
                .controlSize(.small)
                .help("Record the current resolution into this slot")
            }
        }
    }
}
