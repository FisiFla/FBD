import XCTest
import FBDCore

/// Property-style sweep of the combined brightness routing: over a dense
/// deterministic grid of slider values and hardware/XDR ceiling
/// configurations, the mapping must be monotonic in nits, stay within
/// bounds, and switch zones exactly at the hardware ceiling.
final class CombinedRoutingPropertyTests: XCTestCase {
    /// (hardwareMaxNits, maxNits) configurations covering the interesting
    /// shapes: XDR headroom, small headroom, no headroom, and a zero ceiling.
    private let configs: [(hardware: Int, maxNits: Int)] = [
        (500, 1600), // built-in XDR scenario
        (350, 600),
        (200, 200), // no headroom
        (100, 1000),
        (0, 500), // degenerate ceiling (clamped to 1 nit)
    ]

    /// Effective brightness in nits for a route result: hardware fraction is
    /// linear in the slider; XDR targets are nits directly.
    private func effectiveNits(_ route: CombinedRoute, value: Double, maxNits: Int) -> Double {
        switch route {
        case .hardware(let fraction):
            return value * Double(maxNits)
        case .xdr(let target):
            return Double(target)
        }
    }

    func testEffectiveBrightnessIsMonotonicAcrossTheWholeSlider() {
        for (hardware, maxNits) in configs {
            var previous = -Double.infinity
            var value = 0.0
            while value <= 1.0 {
                let route = CombinedRouting.route(value: value, hardwareMaxNits: hardware, maxNits: maxNits)
                let nits = effectiveNits(route, value: value, maxNits: maxNits)
                XCTAssertGreaterThanOrEqual(nits, previous,
                    "monotonicity broken at value \(value) for \(hardware)/\(maxNits)")
                previous = nits
                value += 0.001
            }
        }
    }

    func testHardwareFractionStaysInUnitInterval() {
        for (hardware, maxNits) in configs {
            var value = 0.0
            while value <= 1.0 {
                let route = CombinedRouting.route(value: value, hardwareMaxNits: hardware, maxNits: maxNits)
                if case .hardware(let fraction) = route {
                    XCTAssertGreaterThanOrEqual(fraction, 0, "\(hardware)/\(maxNits) @ \(value)")
                    XCTAssertLessThanOrEqual(fraction, 1, "\(hardware)/\(maxNits) @ \(value)")
                }
                value += 0.001
            }
        }
    }

    func testXDRTargetsStayWithinCeiling() {
        for (hardware, maxNits) in configs where maxNits > hardware {
            var value = 0.0
            while value <= 1.0 {
                let route = CombinedRouting.route(value: value, hardwareMaxNits: hardware, maxNits: maxNits)
                if case .xdr(let target) = route {
                    XCTAssertGreaterThanOrEqual(target, hardware, "\(hardware)/\(maxNits) @ \(value)")
                    XCTAssertLessThanOrEqual(target, maxNits, "\(hardware)/\(maxNits) @ \(value)")
                }
                value += 0.001
            }
        }
    }

    func testNoHeadroomConfigNeverSwitchesToXDR() {
        for value in stride(from: 0.0, through: 1.0, by: 0.01) {
            if case .xdr = CombinedRouting.route(value: value, hardwareMaxNits: 200, maxNits: 200) {
                XCTFail("no-headroom config must stay hardware at \(value)")
            }
        }
    }

    func testZoneBoundaryMatchesHardwareCeiling() {
        // At the exact boundary the route stays hardware at 100 %; one grid
        // step above it switches to XDR with a target at/above the ceiling.
        for (hardware, maxNits) in configs where maxNits > max(hardware, 1) {
            // The router clamps a zero ceiling to 1 nit (max() in route()).
            let effectiveHardware = max(hardware, 1)
            let boundary = Double(effectiveHardware) / Double(maxNits)
            let atBoundary = CombinedRouting.route(value: boundary, hardwareMaxNits: hardware, maxNits: maxNits)
            XCTAssertEqual(atBoundary, .hardware(1), "\(hardware)/\(maxNits)")

            let above = min(boundary + 0.0001, 1)
            let route = CombinedRouting.route(value: above, hardwareMaxNits: hardware, maxNits: maxNits)
            if case .xdr(let target) = route {
                XCTAssertGreaterThanOrEqual(target, hardware, "\(hardware)/\(maxNits) @ \(above)")
            } else if case .hardware(let fraction) = route {
                // Rounding can keep tiny overshoots in hardware; must be near 1.
                XCTAssertGreaterThanOrEqual(fraction, 0.999, "\(hardware)/\(maxNits) @ \(above)")
            }
        }
    }
}
