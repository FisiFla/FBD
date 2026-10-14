import CoreGraphics
import Foundation

/// Matching the GUI scale across displays.
///
/// "GUI scale" here is **logical points per millimetre of panel** — how large the
/// interface actually looks. Two panels showing the same pixel width do not look the
/// same: 1920 points on a 24" panel is far chunkier than on a 16" one, so dragging a
/// window between them changes its apparent size. Matching means choosing, per
/// display, the mode whose points-per-millimetre is closest to a reference display's.
///
/// The physical size comes from `CGDisplayScreenSize`, which FBD did not previously
/// call. It is not always trustworthy — a panel whose EDID carries no size reports
/// zeros — so everything here fails closed rather than computing a scale from a zero
/// width, which would give infinity and then "match" every display to it.
///
/// Pure: a `Candidate` is a mode reduced to a logical width and a scale, so the choice
/// is testable without a display, a mode list or a resolution change.
public enum UIScaleMatching {
    /// One mode, reduced to what the choice needs.
    public struct Candidate: Equatable, Sendable {
        /// Caller-owned mode identifier (FBD passes the CG mode number).
        public let modeID: Int32
        /// Logical width in points — what the interface lays out against.
        public let logicalWidth: Double
        /// Points per millimetre of panel.
        public let scale: Double

        public init(modeID: Int32, logicalWidth: Double, scale: Double) {
            self.modeID = modeID
            self.logicalWidth = logicalWidth
            self.scale = scale
        }
    }

    /// What to do about one display.
    public enum Plan: Equatable, Sendable {
        /// Nothing on offer comes within tolerance. Nothing is changed: moving every
        /// window on a display without achieving the match is worse than leaving it.
        case noCandidate
        /// Already close enough. Changing would move windows for no visible gain.
        case alreadyMatched(scale: Double)
        /// Apply this mode.
        case changeTo(Candidate)

        public var candidate: Candidate? {
            if case .changeTo(let candidate) = self { return candidate }
            return nil
        }
    }

    /// Points per millimetre. Nil when either input is unusable.
    public static func scale(logicalWidth: Double, physicalWidthMM: Double) -> Double? {
        guard physicalWidthMM > 0, logicalWidth > 0,
              physicalWidthMM.isFinite, logicalWidth.isFinite else { return nil }
        return logicalWidth / physicalWidthMM
    }

    /// Deciding factor: `|scale − target| / max(scale, target)`.
    ///
    /// A **relative** difference, and symmetric because of the `max`: 5→6 and 6→5 are
    /// equally far apart. A plain subtraction would call 10 points/mm off at a scale of
    /// 100 a bigger error than 10 off at a scale of 5, which is backwards; and `|s/t −
    /// 1|` — the first thing I wrote here — is not symmetric at all, which the tests
    /// caught at the tolerance boundary.
    public static func ratioDistance(_ scale: Double, _ target: Double) -> Double {
        guard scale > 0, scale.isFinite, target > 0, target.isFinite else { return .infinity }
        return abs(scale - target) / max(scale, target)
    }

    /// The candidate closest to `target` by ratio. Ties go to the **smaller logical
    /// width** so the answer cannot depend on the order the modes arrived in.
    public static func closest(to target: Double, among candidates: [Candidate]) -> Candidate? {
        guard target > 0, target.isFinite else { return nil }
        return candidates
            .filter { $0.scale > 0 && $0.scale.isFinite }
            .min { lhs, rhs in
                let left = ratioDistance(lhs.scale, target)
                let right = ratioDistance(rhs.scale, target)
                if left == right { return lhs.logicalWidth < rhs.logicalWidth }
                return left < right
            }
    }

    /// Decide for one display.
    ///
    /// `tolerance` is a ratio — 0.02 means "within 2%" — and it applies twice: a
    /// display already inside it is left alone, and a candidate only qualifies if it
    /// is inside it too. So the only changes that happen are changes that achieve the
    /// match.
    public static func plan(
        target: Double,
        current: Candidate?,
        candidates: [Candidate],
        tolerance: Double = 0.02
    ) -> Plan {
        guard target > 0, target.isFinite else { return .noCandidate }
        if let current, ratioDistance(current.scale, target) <= tolerance {
            return .alreadyMatched(scale: current.scale)
        }
        let qualifying = candidates.filter {
            $0.scale > 0 && $0.scale.isFinite && ratioDistance($0.scale, target) <= tolerance
        }
        guard let best = closest(to: target, among: qualifying) else { return .noCandidate }
        return .changeTo(best)
    }
}
