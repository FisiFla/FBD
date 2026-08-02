import XCTest
import FBDCore

/// Property-style sweep of the XDR boost planner: over dense grids of slider
/// values and ceiling/capability combinations, the plan must stay in the
/// expected zones and never produce contradictory outcomes.
final class XDRBoostPlannerPropertyTests: XCTestCase {
    private struct Config: CaseIterable {
        let maxNits: Int
        let hardware: Int
        let native: Bool
        let software: Bool
        static let allCases: [Config] = [
            Config(maxNits: 1600, hardware: 500, native: true, software: true),
            Config(maxNits: 1600, hardware: 500, native: false, software: true),
            Config(maxNits: 1600, hardware: 500, native: false, software: false),
            Config(maxNits: 600, hardware: 350, native: true, software: false),
            Config(maxNits: 500, hardware: 500, native: true, software: true), // no headroom
            Config(maxNits: 500, hardware: 0, native: true, software: true), // zero ceiling
        ]
    }

    func testHardwareZoneCoversExactlyUpToTheCeiling() {
        for config in Config.allCases where config.maxNits > max(config.hardware, 1) {
            let boundary = Double(max(config.hardware, 1)) / Double(config.maxNits)
            // Just below the boundary: hardware.
            let below = XDRBoostPlanner.plan(
                value: max(boundary - 0.001, 0),
                maxNits: config.maxNits,
                hardwareMaxNits: config.hardware,
                nativeAvailable: config.native,
                softwareEnabled: config.software
            )
            if case .hardware = below {} else {
                XCTFail("below-boundary must be hardware: \(config)")
            }
            // Just above the boundary: never hardware.
            let above = XDRBoostPlanner.plan(
                value: min(boundary + 0.001, 1),
                maxNits: config.maxNits,
                hardwareMaxNits: config.hardware,
                nativeAvailable: config.native,
                softwareEnabled: config.software
            )
            if case .hardware = above {
                XCTFail("above-boundary must not be hardware: \(config)")
            }
        }
    }

    func testSoftwareZoneOnlyWhenEnabledAndNativeUnavailable() {
        for config in Config.allCases {
            var value = 0.0
            while value <= 1.0 {
                let plan = XDRBoostPlanner.plan(
                    value: value,
                    maxNits: config.maxNits,
                    hardwareMaxNits: config.hardware,
                    nativeAvailable: config.native,
                    softwareEnabled: config.software
                )
                if case .softwareBoost = plan {
                    XCTAssertFalse(config.native, "software must not be chosen when native is available: \(config) @ \(value)")
                    XCTAssertTrue(config.software, "software must not be chosen when disabled: \(config) @ \(value)")
                }
                if case .nativeUpscale = plan {
                    XCTAssertTrue(config.native, "native must not be chosen when unavailable: \(config) @ \(value)")
                }
                value += 0.01
            }
        }
    }

    func testFailOnlyWhenNoPathExists() {
        for config in Config.allCases {
            var value = 0.0
            while value <= 1.0 {
                let plan = XDRBoostPlanner.plan(
                    value: value,
                    maxNits: config.maxNits,
                    hardwareMaxNits: config.hardware,
                    nativeAvailable: config.native,
                    softwareEnabled: config.software
                )
                if case .fail = plan {
                    let aboveCeiling = value * Double(config.maxNits) > Double(max(config.hardware, 1))
                    XCTAssertTrue(aboveCeiling && !config.native && !config.software,
                        "fail must only occur with no path above the ceiling: \(config) @ \(value)")
                }
                value += 0.01
            }
        }
    }
}
