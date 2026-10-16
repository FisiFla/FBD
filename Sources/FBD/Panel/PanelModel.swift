import Combine
import FBDCore
import SwiftUI

/// Popover state: what's shown, where we are, and the actions pages call.
@MainActor
final class PanelModel: ObservableObject {
    @Published private(set) var route: PanelRoute = .home
    @Published private(set) var displays: [Display]
    @Published private(set) var toggles: [QuickToggle] = []
    @Published private(set) var virtualScreenCount = 0
    @Published private(set) var groupCount = 0
    /// Whether each display answered a DDC volume read. Absent = not probed yet = hidden.
    @Published var volumeAvailability: [CGDirectDisplayID: Bool] = [:]

    private let toggleBackend: QuickToggleBackend
    private let counts: () -> (virtualScreens: Int, groups: Int)
    private let resolution = ResolutionController()
    private var observers: [NSObjectProtocol] = []

    init(
        displays: [Display],
        toggleBackend: QuickToggleBackend,
        counts: @escaping () -> (virtualScreens: Int, groups: Int)
    ) {
        self.displays = displays
        self.toggleBackend = toggleBackend
        self.counts = counts
        refreshToggles()
        refreshCounts()
    }

    static func live() -> PanelModel {
        let model = PanelModel(
            displays: DisplayController.shared.displays,
            toggleBackend: SystemQuickToggleBackend(),
            counts: { (VirtualScreenController.shared.screens.count, liveGroupCount()) }
        )
        model.observeSystem()
        return model
    }

    /// Reads the persisted groups afresh on every call: `GroupsPage` edits them
    /// through its own `DisplayGroupsController`, so one held here would go stale.
    static func liveGroupCount(defaults: UserDefaults = FBDCore.Settings.defaults) -> Int {
        DisplayGroupsController(defaults: defaults).groups.count
    }

    // MARK: Navigation

    func open(_ route: PanelRoute) {
        if let id = route.displayID, display(id: id) == nil { self.route = .home; return }
        self.route = route
    }

    func back() {
        if let parent = route.parent { route = parent }
    }

    func display(id: CGDirectDisplayID) -> Display? {
        displays.first { $0.id == id }
    }

    func reloadDisplays(_ displays: [Display]) {
        self.displays = displays
        let present = Set(displays.map(\.id))
        volumeAvailability = volumeAvailability.filter { present.contains($0.key) }
        if let id = route.displayID, display(id: id) == nil { route = .home }
        refreshCounts()
    }

    // MARK: Toggles

    func toggle(_ kind: QuickToggle.Kind) {
        guard let current = toggles.first(where: { $0.id == kind }), current.isAvailable else { return }
        _ = toggleBackend.set(kind, on: !current.isOn)
        refreshToggles()
    }

    func refreshToggles() {
        toggles = QuickToggle.Kind.allCases.map { kind in
            let s = toggleBackend.state(kind)
            return QuickToggle(id: kind, isOn: s.isOn, isAvailable: s.isAvailable)
        }
    }

    func refreshCounts() {
        let c = counts()
        virtualScreenCount = c.virtualScreens
        groupCount = c.groups
    }

    // MARK: Volume

    func showsVolume(forID id: CGDirectDisplayID) -> Bool { volumeAvailability[id] == true }
    func showsVolume(for display: Display) -> Bool { showsVolume(forID: display.id) }

    /// Probes DDC volume once per display. The read happens off the main actor
    /// (`readDDCState`) and the result arrives back on it.
    func probeVolume(for display: Display) {
        guard volumeAvailability[display.id] == nil else { return }
        guard display.ddcAvailable else { volumeAvailability[display.id] = false; return }
        let id = display.id
        DisplayController.shared.readDDCState(for: display) { [weak self] state in
            self?.volumeAvailability[id] = (state.volume != nil)
        }
    }

    // MARK: Presets

    func presets(for display: Display) -> [DisplayPreset] {
        DisplayPresets.presets(for: display.identityKey)
    }

    /// Applies a preset and says what actually happened: a preset can name
    /// properties this display cannot report, and passing those off as applied
    /// would be worse than not restoring them.
    func apply(_ preset: DisplayPreset, to display: Display) {
        let outcome = DisplayPresetApplier.apply(
            preset, to: display, resolution: resolution, controller: DisplayController.shared
        )
        if outcome.applied.isEmpty && !outcome.requested.isEmpty {
            FBDNotice.shared.report(String(localized: "Nothing in '\(preset.name)' applies to this display."))
        } else if outcome.unavailable.isEmpty {
            FBDNotice.shared.report(String(localized: "Applied '\(preset.name)'."))
        } else {
            FBDNotice.shared.report(String(
                localized: "Applied '\(preset.name)' — skipped \(outcome.unavailable.names.joined(separator: ", "))."
            ))
        }
    }

    // MARK: System observation

    // `MainActor.assumeIsolated` is macOS 14+; the deployment target is 13, so hop with a Task.
    private func observeSystem() {
        let center = NotificationCenter.default
        for name in [Notification.Name.fbdDisplaysChanged, .fbdDisplayUpdated] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reloadDisplays(DisplayController.shared.displays) }
            })
        }
        observers.append(center.addObserver(forName: .fbdVirtualScreensChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCounts() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: DarkModeController.themeChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshToggles() }
        })
    }
}
