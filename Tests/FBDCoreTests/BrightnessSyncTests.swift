import XCTest
@testable import FBDCore

/// Luminance-based brightness mapping (#16).
///
/// The point of these is the *divergence* case: a raw value copied between
/// displays of different ceilings is the bug, so most of the coverage is about
/// ceilings that differ by an order of magnitude.
final class BrightnessSyncTests: XCTestCase {

    func testIdenticalCeilingsAreTheIdentity() {
        for value in [0.0, 0.25, 0.5, 1.0] {
            XCTAssertEqual(
                BrightnessSync.equivalentValue(value, sourceCeilingNits: 500, targetCeilingNits: 500),
                value, accuracy: 1e-9
            )
        }
    }

    func testAMuchBrighterTargetGetsAMuchLowerValue() {
        // 300 nits at full is 0.1875 of a 1600-nit panel's range.
        XCTAssertEqual(
            BrightnessSync.equivalentValue(1.0, sourceCeilingNits: 300, targetCeilingNits: 1600),
            0.1875, accuracy: 1e-9
        )
    }

    func testADimmerTargetSaturatesRatherThanExceedingItsRange() {
        // 1600 nits asked of a 300-nit panel is not reachable; clamp to full
        // rather than emitting a value above 1 that a controller would have to
        // second-guess.
        XCTAssertEqual(
            BrightnessSync.equivalentValue(1.0, sourceCeilingNits: 1600, targetCeilingNits: 300),
            1.0, accuracy: 1e-9
        )
    }

    func testEqualNitsIsThePropertyWithinTheTargetsRange() {
        // The contract, stated directly: the same luminance comes out of both —
        // as long as the target can reach it. 0.1 of a 1600-nit panel is 160
        // nits, comfortably inside a 300-nit panel's range.
        let source = BrightnessSync.nits(0.1, ceilingNits: 1600)
        let mapped = BrightnessSync.equivalentValue(0.1, sourceCeilingNits: 1600, targetCeilingNits: 300)
        let target = BrightnessSync.nits(mapped, ceilingNits: 300)
        XCTAssertEqual(source, target, accuracy: 1e-6)
    }

    func testReachingBeyondTheTargetCeilingSaturatesInstead() {
        // 960 nits cannot be asked of a 300-nit panel, so it saturates at full
        // and the two are deliberately NOT equal in luminance. That is the
        // honest outcome: the target has no brighter state to offer.
        let mapped = BrightnessSync.equivalentValue(0.6, sourceCeilingNits: 1600, targetCeilingNits: 300)
        XCTAssertEqual(mapped, 1.0, accuracy: 1e-9)
        XCTAssertLessThan(
            BrightnessSync.nits(mapped, ceilingNits: 300),
            BrightnessSync.nits(0.6, ceilingNits: 1600)
        )
    }

    func testRoundTripWithinRangeIsStable() {
        // 0.2 of 1000 nits is 200, which a 400-nit panel reaches at half — both
        // ends inside range, so the round trip is exact.
        let there = BrightnessSync.equivalentValue(0.2, sourceCeilingNits: 1000, targetCeilingNits: 400)
        XCTAssertEqual(there, 0.5, accuracy: 1e-9)
        let back = BrightnessSync.equivalentValue(there, sourceCeilingNits: 400, targetCeilingNits: 1000)
        XCTAssertEqual(back, 0.2, accuracy: 1e-9)
    }

    func testMonotonicInValue() {
        var previous = -1.0
        for step in stride(from: 0.0, through: 1.0, by: 0.1) {
            let mapped = BrightnessSync.equivalentValue(step, sourceCeilingNits: 1600, targetCeilingNits: 300)
            XCTAssertGreaterThanOrEqual(mapped, previous)
            previous = mapped
        }
    }

    func testInputBelowZeroAndAboveOneAreClamped() {
        XCTAssertEqual(
            BrightnessSync.equivalentValue(-5, sourceCeilingNits: 500, targetCeilingNits: 500), 0, accuracy: 1e-9
        )
        XCTAssertEqual(
            BrightnessSync.equivalentValue(9, sourceCeilingNits: 500, targetCeilingNits: 500), 1, accuracy: 1e-9
        )
    }

    func testUnknownCeilingPassesTheValueThrough() {
        // A ceiling we could not read must not become a divide-by-zero, and must
        // not be treated as "this display has no brightness".
        XCTAssertEqual(
            BrightnessSync.equivalentValue(0.4, sourceCeilingNits: 0, targetCeilingNits: 1600), 0.4, accuracy: 1e-9
        )
        XCTAssertEqual(
            BrightnessSync.equivalentValue(0.4, sourceCeilingNits: 1600, targetCeilingNits: 0), 0.4, accuracy: 1e-9
        )
        XCTAssertEqual(BrightnessSync.nits(0.4, ceilingNits: 0), 0)
    }
}
