import Foundation

// MARK: - Model

/// One resolution favourite: the display mode a user parked in a numbered
/// slot, stored per display identity.
///
/// Mirrors BetterDisplay's five "resolution favourite" slots. A favourite
/// records both the CGS mode *number* (which identifies the exact mode, but
/// only within one display session) and the mode's *shape* (logical size,
/// pixel size, refresh rate, HiDPI) so it can be re-matched against a fresh
/// mode list after a reconnect.
public struct ModeFavourite: Codable, Equatable {
    /// 1-based slot index, always within `ModeFavourites.validSlots`.
    public let slot: Int
    /// CGS mode number at the time the favourite was recorded.
    public let modeNumber: Int32
    /// Logical width in points.
    public let width: Int32
    /// Logical height in points.
    public let height: Int32
    /// Backing pixel width.
    public let pixelsWide: Int32
    /// Backing pixel height.
    public let pixelsHigh: Int32
    /// Refresh rate in Hz.
    public let refreshRate: Double
    /// Whether the recorded mode was HiDPI.
    public let isHiDPI: Bool

    public init(
        slot: Int,
        modeNumber: Int32,
        width: Int32,
        height: Int32,
        pixelsWide: Int32,
        pixelsHigh: Int32,
        refreshRate: Double,
        isHiDPI: Bool
    ) {
        self.slot = slot
        self.modeNumber = modeNumber
        self.width = width
        self.height = height
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh
        self.refreshRate = refreshRate
        self.isHiDPI = isHiDPI
    }

    /// Capture `mode` into `slot`.
    public init(slot: Int, mode: DisplayMode) {
        self.init(
            slot: slot,
            modeNumber: mode.modeNumber,
            width: mode.width,
            height: mode.height,
            pixelsWide: mode.pixelsWide,
            pixelsHigh: mode.pixelsHigh,
            refreshRate: mode.refreshRate,
            isHiDPI: mode.isHiDPI
        )
    }
}

/// How a stored favourite resolved against a display's current mode list.
public enum ModeRecall: Equatable {
    /// The exact recorded mode (same CGS mode number) is still offered.
    case exact(DisplayMode)
    /// The recorded mode number is gone, but a mode with the same pixel size
    /// and refresh rate is offered.
    case equivalent(DisplayMode)
    /// Nothing in the current list matches — apply nothing and report it.
    case unavailable

    /// The mode to apply, or nil when the favourite is unavailable.
    public var displayMode: DisplayMode? {
        switch self {
        case .exact(let mode), .equivalent(let mode): return mode
        case .unavailable: return nil
        }
    }

    /// True only for the `.unavailable` outcome.
    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

// MARK: - Filter options

/// Toggles for `ModeFavourites.filter`, mirroring BetterDisplay's resolution
/// list options. Every boolean defaults to the conservative desktop view.
public struct ModeFilterOptions: Equatable {
    /// Include *mixed* modes — HiDPI modes with a fractional scale (the backing
    /// pixels are not exactly 2× the logical points). Hidden by default.
    public var showMixedModes: Bool
    /// Include modes that are not flagged safe, or that are degenerate
    /// (zero/negative width or height). Hidden by default.
    public var showUnsafeOrInvalid: Bool
    /// Include modes whose shorter side is below 720 points. Hidden by default.
    public var includeBelow720p: Bool
    /// Include modes whose longer side exceeds 7680 pixels (8K). Hidden by
    /// default.
    public var includeAbove8K: Bool
    /// Keep HiDPI modes even when the size or safety filters would drop them.
    /// On by default: HiDPI is what users usually want, so it wins over the
    /// size/safety exclusions. It does *not* override `showMixedModes` or
    /// `onlyNativeAspect`.
    public var alwaysShowHiDPI: Bool
    /// When a native aspect ratio is supplied to `filter`, keep only modes
    /// matching it. Off by default (every aspect ratio is kept).
    public var onlyNativeAspect: Bool

    public init(
        showMixedModes: Bool = false,
        showUnsafeOrInvalid: Bool = false,
        includeBelow720p: Bool = false,
        includeAbove8K: Bool = false,
        alwaysShowHiDPI: Bool = true,
        onlyNativeAspect: Bool = false
    ) {
        self.showMixedModes = showMixedModes
        self.showUnsafeOrInvalid = showUnsafeOrInvalid
        self.includeBelow720p = includeBelow720p
        self.includeAbove8K = includeAbove8K
        self.alwaysShowHiDPI = alwaysShowHiDPI
        self.onlyNativeAspect = onlyNativeAspect
    }

    /// The default desktop view: safe, ≥720p, ≤8K, HiDPI kept, mixed hidden.
    public static let standard = ModeFilterOptions()
}

// MARK: - Favourites, filters and rates

/// Resolution favourites: five slots per display, persisted as JSON in the
/// suite-aware defaults, plus the pure filters and refresh-rate helpers the
/// resolution list needs.
///
/// Every decision-shaped member here is pure (`resolve`, `filter`,
/// `refreshRates`, `refreshRateLabel`, `mode(in:matchingRefreshRate:)`) so it
/// can be unit-tested with no display attached. The persistence helpers read
/// and write `Settings.defaults` (the suite-aware accessor) by default and
/// accept an injected suite so tests stay off the real domain.
public enum ModeFavourites {
    /// Number of slots BetterDisplay exposes.
    public static let slotCount = 5
    /// The valid slot range, 1...5.
    public static let validSlots = 1...slotCount

    /// Refresh rates within this many Hz are treated as the same rate.
    static let refreshRateTolerance = 0.01
    /// Aspect ratios within this many units are treated as matching.
    static let aspectTolerance = 0.02

    // MARK: Persistence

    /// UserDefaults key for a display identity's favourites (a JSON array).
    static func defaultsKey(for identity: String) -> String { "modeFavourites.\(identity)" }

    /// Record `mode` into `slot` for `identity`. Returns false — and writes
    /// nothing — when `slot` is outside `validSlots`.
    @discardableResult
    public static func save(
        _ mode: DisplayMode,
        into slot: Int,
        for identity: String,
        defaults: UserDefaults = Settings.defaults
    ) -> Bool {
        guard validSlots.contains(slot) else { return false }
        var slots = storedSlots(for: identity, defaults: defaults)
        slots[slot] = ModeFavourite(slot: slot, mode: mode)
        write(slots, for: identity, defaults: defaults)
        return true
    }

    /// The favourite in `slot`, or nil when the slot is empty or out of range.
    public static func favourite(
        slot: Int,
        for identity: String,
        defaults: UserDefaults = Settings.defaults
    ) -> ModeFavourite? {
        guard validSlots.contains(slot) else { return nil }
        return storedSlots(for: identity, defaults: defaults)[slot]
    }

    /// Remove `slot` for `identity`. Idempotent: returns false only for an
    /// out-of-range slot, and true for any valid slot (clearing an already
    /// empty one is a no-op that still reports success).
    @discardableResult
    public static func clear(
        slot: Int,
        for identity: String,
        defaults: UserDefaults = Settings.defaults
    ) -> Bool {
        guard validSlots.contains(slot) else { return false }
        var slots = storedSlots(for: identity, defaults: defaults)
        slots.removeValue(forKey: slot)
        write(slots, for: identity, defaults: defaults)
        return true
    }

    /// Every non-empty slot for `identity`, ordered by slot.
    public static func favourites(
        for identity: String,
        defaults: UserDefaults = Settings.defaults
    ) -> [ModeFavourite] {
        storedSlots(for: identity, defaults: defaults)
            .values
            .sorted { $0.slot < $1.slot }
    }

    private static func storedSlots(
        for identity: String,
        defaults: UserDefaults
    ) -> [Int: ModeFavourite] {
        guard let data = defaults.data(forKey: defaultsKey(for: identity)),
              let list = try? JSONDecoder().decode([ModeFavourite].self, from: data) else {
            return [:]
        }
        var slots: [Int: ModeFavourite] = [:]
        for favourite in list where validSlots.contains(favourite.slot) {
            slots[favourite.slot] = favourite
        }
        return slots
    }

    private static func write(
        _ slots: [Int: ModeFavourite],
        for identity: String,
        defaults: UserDefaults
    ) {
        let key = defaultsKey(for: identity)
        guard !slots.isEmpty else {
            // Drop the key entirely rather than storing "[]", so an identity
            // whose last favourite was cleared leaves no residue behind.
            defaults.removeObject(forKey: key)
            return
        }
        let ordered = slots.values.sorted { $0.slot < $1.slot }
        guard let data = try? JSONEncoder().encode(ordered) else { return }
        defaults.set(data, forKey: key)
    }

    // MARK: Recall

    /// Resolve `favourite` against a display's current `modes`: the exact mode
    /// when the recorded mode number still exists, otherwise an equivalent mode
    /// with the same pixel size and refresh rate, otherwise `.unavailable`.
    ///
    /// Pure — needs neither a display nor defaults. A mode that does not match
    /// exactly *or* equivalently is reported unavailable rather than guessed,
    /// so a wrong mode is never applied silently.
    public static func resolve(_ favourite: ModeFavourite, against modes: [DisplayMode]) -> ModeRecall {
        if let exact = modes.first(where: { $0.modeNumber == favourite.modeNumber }) {
            return .exact(exact)
        }
        if let equivalent = modes.first(where: {
            $0.pixelsWide == favourite.pixelsWide
                && $0.pixelsHigh == favourite.pixelsHigh
                && abs($0.refreshRate - favourite.refreshRate) <= refreshRateTolerance
        }) {
            return .equivalent(equivalent)
        }
        return .unavailable
    }

    /// Read `slot` for `identity` and resolve it against `modes`; `.unavailable`
    /// when the slot is empty.
    public static func recall(
        slot: Int,
        for identity: String,
        against modes: [DisplayMode],
        defaults: UserDefaults = Settings.defaults
    ) -> ModeRecall {
        guard let favourite = favourite(slot: slot, for: identity, defaults: defaults) else {
            return .unavailable
        }
        return resolve(favourite, against: modes)
    }

    // MARK: Filtering

    /// Filter `modes` for the resolution list. Total (never throws or traps)
    /// and order-preserving: surviving modes keep their input order.
    public static func filter(
        _ modes: [DisplayMode],
        options: ModeFilterOptions,
        nativeAspect: Double?
    ) -> [DisplayMode] {
        modes.filter { survives($0, options: options, nativeAspect: nativeAspect) }
    }

    private static func survives(
        _ mode: DisplayMode,
        options: ModeFilterOptions,
        nativeAspect: Double?
    ) -> Bool {
        // A HiDPI mode is what users usually want, so with `alwaysShowHiDPI` it
        // bypasses the *size* and *safety* exclusions — but not the mixed or
        // aspect rules, which are about the mode's shape, not its importance.
        let hiDPIPass = options.alwaysShowHiDPI && mode.isHiDPI
        let shorterSide = min(mode.width, mode.height)
        let longerSide = max(mode.width, mode.height)
        let degenerate = mode.width <= 0 || mode.height <= 0

        if (degenerate || !mode.isSafe) && !options.showUnsafeOrInvalid && !hiDPIPass {
            return false
        }
        if shorterSide < 720 && !options.includeBelow720p && !hiDPIPass {
            return false
        }
        if longerSide > 7680 && !options.includeAbove8K && !hiDPIPass {
            return false
        }
        if isMixed(mode) && !options.showMixedModes {
            return false
        }
        if options.onlyNativeAspect, let nativeAspect, nativeAspect > 0, mode.height != 0 {
            let aspect = Double(mode.width) / Double(mode.height)
            if abs(aspect - nativeAspect) > aspectTolerance {
                return false
            }
        }
        return true
    }

    /// A *mixed* mode is HiDPI but not a clean 2× — its backing pixels are not
    /// exactly twice its logical points (a scaled "more space" style mode).
    public static func isMixed(_ mode: DisplayMode) -> Bool {
        guard mode.isHiDPI else { return false }
        return mode.pixelsWide != mode.width * 2 || mode.pixelsHigh != mode.height * 2
    }

    // MARK: Refresh rates

    /// Distinct refresh rates across `modes`, descending, with zero and
    /// non-finite rates dropped. Rates within `refreshRateTolerance` (0.01 Hz)
    /// collapse to a single entry (the first seen).
    ///
    /// **Limitation — the unexposed-rate gap.** BetterDisplay also lists
    /// *unexposed* (NTSC-style) timings, which it obtains from private SkyLight
    /// mode queries. `docs/PRIVATE_APIS.md` records that those queries require
    /// a live WindowServer connection and **crash** a process that has none, so
    /// this implementation deliberately derives the list only from the modes
    /// already enumerated by the CGS mode APIs. The gap is documented, not
    /// faked: a rate a TV or Safari would show, but macOS never enumerated
    /// here, will not appear.
    public static func refreshRates(from modes: [DisplayMode]) -> [Double] {
        var unique: [Double] = []
        for mode in modes {
            let hz = mode.refreshRate
            guard hz.isFinite, hz > 0 else { continue }
            if unique.contains(where: { abs($0 - hz) <= refreshRateTolerance }) { continue }
            unique.append(hz)
        }
        return unique.sorted(by: >)
    }

    /// A rate rendered for the UI: whole rates as "60 Hz", fractional ones as
    /// "59.94 Hz". Empty for a zero or non-finite input, so a caller can print
    /// it unconditionally without inventing a value.
    public static func refreshRateLabel(_ hz: Double) -> String {
        guard hz.isFinite, hz > 0 else { return "" }
        if abs(hz - hz.rounded()) < 0.005 {
            return String(format: "%.0f Hz", hz.rounded())
        }
        return String(format: "%.2f Hz", hz)
    }

    /// The mode whose refresh rate is nearest to `hz` within `tolerance`, or
    /// nil when none is close enough. Pure.
    public static func mode(
        in modes: [DisplayMode],
        matchingRefreshRate hz: Double,
        tolerance: Double = 0.01
    ) -> DisplayMode? {
        var best: DisplayMode?
        var bestDelta = Double.greatestFiniteMagnitude
        for mode in modes {
            let delta = abs(mode.refreshRate - hz)
            if delta <= tolerance && delta < bestDelta {
                best = mode
                bestDelta = delta
            }
        }
        return best
    }
}

// MARK: - Settings accessors

/// Per-identity accessors, following the same shape as the existing
/// per-identity helpers on `Settings` (`ddcFeatures(for:)`,
/// `cornerRadius(for:)`). They live here — not in `Settings.swift` — and are a
/// thin front for `ModeFavourites`, so there is exactly one storage path.
extension Settings {
    /// Persisted resolution favourites for `identity`, ordered by slot.
    public static func modeFavourites(for identity: String) -> [ModeFavourite] {
        ModeFavourites.favourites(for: identity)
    }

    /// The persisted favourite in `slot`, or nil when empty / out of range.
    public static func modeFavourite(slot: Int, for identity: String) -> ModeFavourite? {
        ModeFavourites.favourite(slot: slot, for: identity)
    }

    /// Persist `mode` into `slot`; false for an out-of-range slot.
    @discardableResult
    public static func setModeFavourite(
        _ mode: DisplayMode,
        slot: Int,
        for identity: String
    ) -> Bool {
        ModeFavourites.save(mode, into: slot, for: identity)
    }

    /// Clear `slot`; false for an out-of-range slot.
    @discardableResult
    public static func clearModeFavourite(slot: Int, for identity: String) -> Bool {
        ModeFavourites.clear(slot: slot, for: identity)
    }
}
