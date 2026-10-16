import FBDCore
import SwiftUI

/// Redraw trigger for the Settings pages.
///
/// `Settings` is a plain enum over UserDefaults with no observation, so a control that writes it
/// would never see its own label or stepper value update. Pages hold this object; any defaults
/// change bumps `tick` and re-evaluates their bodies, which re-read `Settings`.
///
/// It also latches `.fbdHotkeysUnavailable`, which is posted once at launch, before any Settings
/// page exists — a page that only listened with `onReceive` would never see it.
@MainActor
final class SettingsObserver: ObservableObject {
    static let shared = SettingsObserver()

    @Published private(set) var tick = 0
    @Published private(set) var hotkeysUnavailable = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Deferred a runloop turn: a control that writes a default while SwiftUI is updating
            // a view would otherwise publish a change from within that update.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.tick &+= 1 }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .fbdHotkeysUnavailable, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotkeysUnavailable = true }
        })
    }
}
