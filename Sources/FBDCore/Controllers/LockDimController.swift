import CoreGraphics
import Foundation
import os

// MARK: - Pure decision layer

/// Whether (and how far) to dim the display while the screen is locked, and the
/// target brightness. Persisted through `Settings` — the controller reads and
/// writes the `lockDimEnabled` / `lockDimTargetPercent` keys in the suite-aware
/// `defaults`, so the app and the CLI share one copy.
public struct LockDimPolicy: Equatable, Codable {
    /// Whether lock/screensaver dimming is on. Off by default, so a fresh
    /// install never touches brightness until the user opts in.
    public var enabled: Bool
    /// Brightness percentage (0…100) to dim to while locked: 0 is fully dark,
    /// 100 is no dim at all. Normalised by `clamped()`.
    public var targetPercent: Double

    /// Target used when the setting has never been written. Kept in sync with
    /// the `Storage` default of `Settings.lockDimTargetPercent`.
    public static let defaultTargetPercent: Double = 10

    public init(enabled: Bool, targetPercent: Double) {
        self.enabled = enabled
        self.targetPercent = targetPercent
    }

    /// The same policy with `targetPercent` normalised into 0…100. A `NaN`
    /// target becomes 0 rather than being handed on to the brightness seam — it
    /// compares false against every bound, so `min`/`max` alone would let it
    /// through.
    public func clamped() -> LockDimPolicy {
        LockDimPolicy(enabled: enabled, targetPercent: LockDimPolicy.normalisedPercent(targetPercent))
    }

    /// The brightness fraction (0…1) this policy asks a `LockDimApplying` for.
    var dimValue: Double { LockDimPolicy.normalisedPercent(targetPercent) / 100 }

    private static func normalisedPercent(_ percent: Double) -> Double {
        guard !percent.isNaN else { return 0 }
        return min(max(percent, 0), 100)
    }
}

/// The two lock-related transitions the controller cares about.
public enum LockDimEvent: Equatable {
    /// The screen locked (or the screensaver engaged).
    case screenLocked
    /// The screen unlocked (or the screensaver was dismissed).
    case screenUnlocked
}

/// What to do about a `LockDimEvent` once the current brightness is known. A
/// pure value — it names an effect, it does not perform one.
public enum LockDimAction: Equatable {
    /// Leave brightness alone.
    case none
    /// Dim the display to this brightness (0…1).
    case dim(to: Double)
    /// Restore the display to this previously-recorded brightness (0…1).
    case restore(to: Double)
}

/// The whole lock-dimming decision as a pure function of (event, policy, current
/// brightness).
///
/// The single piece of state it carries is the brightness recorded at lock time
/// — the only thing that lets a later unlock put the screen back exactly where
/// it was. Capturing the value *before* it is overwritten is the fail-closed-open
/// guarantee: a dim can always be undone, and a lock whose brightness cannot be
/// read never dims at all.
public struct LockDimStateMachine: Equatable {
    /// Brightness (0…1) captured when the screen locked and not yet restored.
    /// `nil` means "we did not dim anything" (or we already restored).
    public private(set) var recordedBrightness: Double?

    public init() {}

    /// Apply one event. Total and pure: no trapping, no I/O, and every branch
    /// returns an action.
    ///
    /// - A disabled policy is inert: `.none` for every event, and nothing is
    ///   recorded, so a policy that is off can never leave a record behind.
    /// - On lock, a *known* brightness is recorded and dimmed to the target; an
    ///   *unknown* brightness returns `.none` — better to leave the screen alone
    ///   than to dim toward a value we could not restore.
    /// - A second lock while already locked returns `.none` and leaves the
    ///   recorded brightness untouched (idempotent), so the original is not lost.
    /// - On unlock the recorded brightness is restored and the record cleared;
    ///   with nothing recorded it is `.none`.
    public mutating func handle(
        _ event: LockDimEvent,
        policy: LockDimPolicy,
        currentBrightness: Double?
    ) -> LockDimAction {
        guard policy.enabled else { return .none }
        switch event {
        case .screenLocked:
            // Already locked (a record is held): idempotent — never overwrite.
            guard recordedBrightness == nil else { return .none }
            // Never dim blind: without a real current value there is nothing to
            // restore to, so leave the screen untouched.
            guard let current = currentBrightness else { return .none }
            recordedBrightness = current
            return .dim(to: policy.dimValue)
        case .screenUnlocked:
            guard let recorded = recordedBrightness else { return .none }
            recordedBrightness = nil
            return .restore(to: recorded)
        }
    }

    /// Force the recorded brightness back, regardless of the current policy, and
    /// clear the record. The fail-closed-open escape hatch: used when the
    /// controller stops (or the policy is switched off mid-lock) so a dim is
    /// always reversible even if no unlock event will arrive.
    public mutating func restoreRecorded() -> LockDimAction {
        guard let recorded = recordedBrightness else { return .none }
        recordedBrightness = nil
        return .restore(to: recorded)
    }
}

// MARK: - Effect seam

/// The brightness effect the controller drives. Kept to the two things the
/// decision layer needs — read the current value, write a new one — so a test
/// can inject a fake and never touch real hardware.
public protocol LockDimApplying: AnyObject {
    /// Current brightness 0…1, or `nil` when no display/brightness is readable.
    func currentBrightness() -> Double?
    /// Apply a brightness 0…1.
    func setBrightness(_ value: Double)
}

/// Default adapter: read/write the *main* display's brightness through the
/// shared `DisplayController` — FBD's existing brightness seam (the Apple and
/// DDC paths both route through it). The main display is the one the user is
/// actually looking at, which is the one worth dimming on lock.
///
/// Non-`@MainActor` on purpose: it satisfies the non-isolated `LockDimApplying`
/// requirement while still reaching the `@MainActor` `DisplayController`, by
/// bridging with `MainActor.assumeIsolated` after hopping to the main queue —
/// the same pattern `CombinedBrightness`/`DisplayGroupsController` use. The
/// lock/unlock observers are registered with `queue: .main`, so the normal path
/// is already on the main thread and the hop is only a safety net.
public final class MainDisplayLockDimAdapter: LockDimApplying {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "LockDimController")

    public init() {}

    public func currentBrightness() -> Double? {
        onMain { controller in
            guard let display = Self.targetDisplay(in: controller) else { return nil }
            return controller.getBrightness(for: display)
        }
    }

    public func setBrightness(_ value: Double) {
        let log = log
        onMain { controller in
            guard let display = Self.targetDisplay(in: controller) else {
                log.warning("no display to dim — skipping brightness write")
                return
            }
            controller.setBrightness(value, on: display)
        }
    }

    /// The display to dim: the one macOS flags as main, falling back to the
    /// first active display on a machine that reports none.
    @MainActor
    private static func targetDisplay(in controller: DisplayController) -> Display? {
        controller.displays.first(where: { CGDisplayIsMain($0.id) != 0 }) ?? controller.displays.first
    }

    @discardableResult
    private func onMain<T>(_ body: @MainActor (DisplayController) -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body(DisplayController.shared) }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body(DisplayController.shared) } }
    }
}

// MARK: - Controller

/// Dim the display while the screen is locked (or the screensaver is up) and
/// restore it on unlock — BetterDisplay parity.
///
/// All decisions live in `LockDimStateMachine` (pure, hardware-free); this class
/// only wires macOS's distributed lock/unlock notifications to it and persists
/// the policy. Effects go through the injected `LockDimApplying` seam, so a fake
/// stands in for the display in tests.
///
/// Fail-closed-open: the machine records the pre-dim brightness *before*
/// overwriting it, never dims when the current brightness is unknown, and can
/// always force the value back (`stop()`), so a bug here cannot strand the
/// user's screen dimmed.
public final class LockDimController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "LockDimController")

    /// Keys mirror `Settings.lockDimEnabled` / `Settings.lockDimTargetPercent`,
    /// read and written through the injected suite so the app, the CLI and tests
    /// all agree on one copy.
    private static let enabledKey = "lockDimEnabled"
    private static let targetKey = "lockDimTargetPercent"
    /// The pre-dim brightness while a lock dim is in force. Persisted so a quit or crash while
    /// locked cannot strand the screen at the dimmed value (which brightness persistence has
    /// stored as the user's level); restored on the next launch.
    private static let preDimKey = "lockDimPreDimBrightness"

    /// macOS's distributed lock/unlock notifications.
    private static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    private static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    /// Persistence domain. Defaults to the suite-aware `Settings.defaults` (the
    /// app and CLI share one copy); injectable so tests use a scratch suite.
    private let defaults: UserDefaults
    private let applier: LockDimApplying

    private var machine = LockDimStateMachine()
    private var observers: [NSObjectProtocol] = []
    private var hasRegistered = false

    public init(
        defaults: UserDefaults = Settings.defaults,
        applier: LockDimApplying = MainDisplayLockDimAdapter()
    ) {
        self.defaults = defaults
        self.applier = applier
    }

    // MARK: - Persistence

    /// The persisted policy, clamped. Absent keys fall back to disabled and the
    /// `Settings` default target, so a display the user never configured stays
    /// untouched.
    public func loadPolicy() -> LockDimPolicy {
        let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        let target = defaults.object(forKey: Self.targetKey) as? Double ?? LockDimPolicy.defaultTargetPercent
        return LockDimPolicy(enabled: enabled, targetPercent: target).clamped()
    }

    /// Persist a policy (clamped) through the injected suite, under the same keys
    /// `Settings` exposes, so there is a single copy.
    public func savePolicy(_ policy: LockDimPolicy) {
        let clamped = policy.clamped()
        defaults.set(clamped.enabled, forKey: Self.enabledKey)
        defaults.set(clamped.targetPercent, forKey: Self.targetKey)
    }

    // MARK: - Lifecycle

    /// Number of registered notification observers. Internal so tests can prove
    /// `start()` is idempotent.
    var registeredObserverCount: Int { observers.count }

    /// Begin observing lock/unlock. Idempotent: a second call is a no-op, so it
    /// never double-registers observers.
    public func start() {
        guard !hasRegistered else { return }
        hasRegistered = true
        restorePersistedPreDim()
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: Self.lockedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.emit(.screenLocked)
        })
        observers.append(center.addObserver(
            forName: Self.unlockedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.emit(.screenUnlocked)
        })
        log.info("lock dim observation started")
    }

    /// Stop observing and never leave the screen dimmed: any brightness recorded
    /// by a lock is restored on the way out.
    public func stop() {
        guard hasRegistered else { return }
        hasRegistered = false
        let center = DistributedNotificationCenter.default()
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        apply(machine.restoreRecorded())
    }

    // MARK: - Event handling

    /// Route one lock/unlock event through the pure machine and apply the
    /// resulting action. Internal so tests can drive the controller with a fake
    /// adapter without round-tripping through the distributed-notification
    /// system.
    func emit(_ event: LockDimEvent) {
        restorePersistedPreDim()
        let policy = loadPolicy()
        guard policy.enabled else {
            // A disabled policy must never leave a dim behind: undo anything a
            // previous policy recorded (e.g. switched off while locked).
            apply(machine.restoreRecorded())
            return
        }
        apply(machine.handle(event, policy: policy, currentBrightness: applier.currentBrightness()))
    }

    private func apply(_ action: LockDimAction) {
        switch action {
        case .none:
            break
        case .dim(let value):
            // Persist the value to return to before the dim overwrites it.
            if let recorded = machine.recordedBrightness {
                defaults.set(recorded, forKey: Self.preDimKey)
            }
            applier.setBrightness(value)
        case .restore(let value):
            applier.setBrightness(value)
            defaults.removeObject(forKey: Self.preDimKey)
        }
    }

    /// A pre-dim value left over from a previous run (quit or crash while locked): put the
    /// screen back. Skipped while this run holds its own record, and kept until a display is
    /// readable so an early call before enumeration retries instead of losing it.
    func restorePersistedPreDim() {
        guard machine.recordedBrightness == nil,
              let saved = defaults.object(forKey: Self.preDimKey) as? Double,
              applier.currentBrightness() != nil else { return }
        applier.setBrightness(min(max(saved, 0), 1))
        defaults.removeObject(forKey: Self.preDimKey)
    }
}
