import XCTest
@testable import FBDCore

/// Row #25: matching the GUI scale across displays.
///
/// Pure, and deliberately so: the alternative way to check this arithmetic is to
/// change a real display's resolution and see whether the result looks right, which
/// moves every open window and cannot be undone by a failed assertion.
final class UIScaleMatchingTests: XCTestCase {
    private func candidate(
        _ modeID: Int32,
        width: Double,
        _ scale: Double
    ) -> UIScaleMatching.Candidate {
        UIScaleMatching.Candidate(modeID: modeID, logicalWidth: width, scale: scale)
    }

    // MARK: - Scale

    func testScaleIsPointsPerMillimetre() {
        XCTAssertEqual(
            UIScaleMatching.scale(logicalWidth: 1728, physicalWidthMM: 344) ?? 0,
            5.023,
            accuracy: 0.01
        )
    }

    /// Every unusable input yields nil rather than a number. A zero panel width would
    /// divide into infinity, and infinity "matches" every display offered to it.
    func testScaleRefusesUnusableInputs() {
        XCTAssertNil(UIScaleMatching.scale(logicalWidth: 1728, physicalWidthMM: 0))
        XCTAssertNil(UIScaleMatching.scale(logicalWidth: 1728, physicalWidthMM: -344))
        XCTAssertNil(UIScaleMatching.scale(logicalWidth: 0, physicalWidthMM: 344))
        XCTAssertNil(UIScaleMatching.scale(logicalWidth: .nan, physicalWidthMM: 344))
        XCTAssertNil(UIScaleMatching.scale(logicalWidth: 1728, physicalWidthMM: .infinity))
    }

    // MARK: - Distance

    /// Ratios, not raw differences: 5→6 and 6→5 must be equally far apart.
    func testDistanceIsSymmetric() {
        XCTAssertEqual(
            UIScaleMatching.ratioDistance(6, 5),
            UIScaleMatching.ratioDistance(5, 6),
            accuracy: 1e-12
        )
        XCTAssertEqual(UIScaleMatching.ratioDistance(6, 5), 1.0 / 6.0, accuracy: 1e-12)
    }

    func testDistanceIsInfiniteForUnusableValues() {
        XCTAssertEqual(UIScaleMatching.ratioDistance(0, 5), .infinity)
        XCTAssertEqual(UIScaleMatching.ratioDistance(5, 0), .infinity)
    }

    // MARK: - Closest

    /// The reason distance is relative: at a target of 100, a scale of 108 is 8% off
    /// while 90 is 10% off — so 108 is the better match even though it is *further*
    /// away in raw points-per-mm. A picker using plain differences would choose 90,
    /// and this is the assertion that fails if that ever gets "simplified".
    func testClosestUsesRelativeDistanceNotPlainDifference() {
        let best = UIScaleMatching.closest(
            to: 100,
            among: [candidate(1, width: 1920, 90), candidate(2, width: 1920, 108)]
        )
        XCTAssertEqual(best?.modeID, 2)
    }

    func testClosestBreaksTiesBySmallerLogicalWidth() {
        // 50 and 200 are each exactly half as far again from a target of 100, so this
        // is a true tie; the smaller logical width must win, deterministically.
        let best = UIScaleMatching.closest(
            to: 100,
            among: [candidate(1, width: 3840, 50), candidate(2, width: 1920, 200)]
        )
        XCTAssertEqual(best?.modeID, 2, "a tie must not be decided by which mode was offered first")
    }

    func testClosestIgnoresUnusableCandidates() {
        let best = UIScaleMatching.closest(
            to: 5,
            among: [
                candidate(1, width: 0, 0),
                candidate(2, width: 1920, .infinity),
                candidate(3, width: 1920, 5.1),
            ]
        )
        XCTAssertEqual(best?.modeID, 3)
    }

    func testClosestIsNilForAnUnusableTarget() {
        XCTAssertNil(UIScaleMatching.closest(to: 0, among: [candidate(1, width: 1920, 5)]))
    }

    // MARK: - Plan

    func testADisplayAlreadyWithinToleranceIsLeftAlone() {
        XCTAssertEqual(
            UIScaleMatching.plan(
                target: 5.0,
                current: candidate(9, width: 1728, 5.05),
                candidates: [candidate(1, width: 1920, 5.0)]
            ),
            .alreadyMatched(scale: 5.05),
            "a change that only moves every window is not worth making"
        )
    }

    func testADisplayOutsideToleranceSwitchesToAQualifyingMode() {
        XCTAssertEqual(
            UIScaleMatching.plan(
                target: 5.0,
                current: candidate(9, width: 2560, 7.4),
                candidates: [candidate(1, width: 1920, 5.02), candidate(2, width: 2560, 7.4)]
            ),
            .changeTo(candidate(1, width: 1920, 5.02))
        )
    }

    /// Fail-closed: if no mode would actually achieve the match, nothing moves.
    func testNoChangeHappensWhenNoModeWouldAchieveTheMatch() {
        XCTAssertEqual(
            UIScaleMatching.plan(
                target: 5.0,
                current: candidate(9, width: 2560, 7.4),
                candidates: [candidate(1, width: 2560, 7.4), candidate(2, width: 3200, 9.3)]
            ),
            .noCandidate
        )
    }

    func testToleranceIsInclusiveAtItsBoundary() {
        // 2% of 5.0 is exactly 0.1.
        XCTAssertEqual(
            UIScaleMatching.plan(target: 5.0, current: candidate(9, width: 1728, 5.1), candidates: []),
            .alreadyMatched(scale: 5.1)
        )
    }

    func testToleranceCanBeTightenedEnoughToRefuseWhatItAccepted() {
        let offered = [candidate(1, width: 1920, 5.1)]
        let current = candidate(9, width: 2560, 7.0)
        XCTAssertEqual(
            UIScaleMatching.plan(target: 5.0, current: current, candidates: offered, tolerance: 0.02),
            .changeTo(offered[0])
        )
        XCTAssertEqual(
            UIScaleMatching.plan(target: 5.0, current: current, candidates: offered, tolerance: 0.01),
            .noCandidate
        )
    }

    func testAnUnreadableCurrentModeStillMatchesAgainstTheOfferedModes() {
        XCTAssertEqual(
            UIScaleMatching.plan(target: 5.0, current: nil, candidates: [candidate(1, width: 1920, 5.0)]),
            .changeTo(candidate(1, width: 1920, 5.0))
        )
    }

    func testAnUnusableTargetPlansNothing() {
        XCTAssertEqual(
            UIScaleMatching.plan(target: 0, current: nil, candidates: [candidate(1, width: 1920, 5.0)]),
            .noCandidate
        )
    }

    func testThePlanExposesACandidateOnlyWhenThereIsOne() {
        XCTAssertEqual(UIScaleMatching.Plan.changeTo(candidate(1, width: 1920, 5)).candidate?.modeID, 1)
        XCTAssertNil(UIScaleMatching.Plan.noCandidate.candidate)
        XCTAssertNil(UIScaleMatching.Plan.alreadyMatched(scale: 5).candidate)
    }
}
