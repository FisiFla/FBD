import Foundation

/// The modes worth offering *at a glance*, with the full list kept behind them.
///
/// The panel needs both halves of this. A menu costs three clicks to pick a resolution
/// (⋯, then Display Mode, then the row); the whole list inline is not a list at all — this
/// machine reports **132** modes — so neither extreme works. Curating is the middle: one entry
/// per logical size at the current mode's aspect ratio, HiDPI preferred, with the mode in
/// effect always present.
///
/// Pure, so what counts as "worth showing" is testable without a display.
public enum CuratedModes {
    /// The most entries to offer inline. Past this the curation has stopped curating.
    public static let limit = 10

    /// Aspect ratios are compared with the same tolerance the mode filter uses, so a
    /// 1920×1080 and a 1919×1080 mode are the same shape rather than two families.
    static let aspectTolerance = 0.01

    /// The short list for `modes`, given the mode in effect.
    ///
    /// The current mode is **always** included: a list that omits what is on screen is how a
    /// picker starts lying about the state, which is the failure this whole area kept
    /// repeating.
    public static func curated(from modes: [DisplayMode], current: DisplayMode?) -> [DisplayMode] {
        guard !modes.isEmpty else { return [] }
        guard let current, current.height != 0 else {
            return Array(modes.prefix(limit))
        }

        let currentAspect = aspect(of: current)
        guard currentAspect > 0 else { return [current] }

        let sameShape = modes.filter { mode in
            mode.height != 0 && abs(aspect(of: mode) - currentAspect) <= aspectTolerance
        }
        guard !sameShape.isEmpty else { return [current] }

        // One entry per logical size, HiDPI preferred, largest first — how macOS lists
        // resolutions.
        let currentKey = SizeKey(width: current.width, height: current.height)
        var bySize: [SizeKey: DisplayMode] = [:]
        for mode in sameShape {
            let key = SizeKey(width: mode.width, height: mode.height)
            if mode.modeNumber == current.modeNumber {
                bySize[key] = mode
                continue
            }
            // The mode in effect owns its own size: swapping in a variant there would leave
            // no row showing what is actually on screen, which is how a picker starts lying.
            if key == currentKey { continue }
            if bySize[key]?.isHiDPI == true { continue }
            bySize[key] = mode
        }

        var result = Array(
            bySize.values.sorted { lhs, rhs in
                lhs.width == rhs.width ? lhs.height > rhs.height : lhs.width > rhs.width
            }
            .prefix(limit)
        )
        // Truncation must never drop the mode in effect; make room rather than leave the list
        // disagreeing with the screen.
        if !result.contains(where: { $0.modeNumber == current.modeNumber }) {
            if result.count >= limit { result.removeLast() }
            result.append(current)
        }
        return result
    }

    /// Whether the full list is worth showing behind the curated one — false when curation
    /// changed nothing, so the affordance is not offered for nothing.
    public static func hidesAnything(from modes: [DisplayMode], current: DisplayMode?) -> Bool {
        curated(from: modes, current: current).count < modes.count
    }

    // MARK: - Internals

    private struct SizeKey: Hashable {
        let width: Int32
        let height: Int32
    }

    private static func aspect(of mode: DisplayMode) -> Double {
        guard mode.height != 0 else { return 0 }
        return Double(mode.width) / Double(mode.height)
    }
}
