import CoreGraphics
import XCTest
@testable import FBDCore

/// Pure-planner tests for the connection-management actions
/// (`ConnectionPlanner`). No WindowServer access — every case is a
/// value → value assertion on `DisplayDescriptor` / `ConnectionStep`.
final class ConnectionManagementTests: XCTestCase {

    // MARK: - Fixtures

    private func display(
        _ id: CGDirectDisplayID,
        online: Bool = true,
        builtin: Bool = false,
        main: Bool = false,
        vendor: UInt32 = 0x1234,
        model: UInt32 = 0x0001,
        serial: UInt32 = 0
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            displayID: id,
            isOnline: online,
            isBuiltin: builtin,
            isMain: main,
            vendor: vendor,
            model: model,
            serial: serial
        )
    }

    private func steps(
        _ action: ConnectionAction,
        _ displays: [DisplayDescriptor],
        override: Bool = false
    ) -> [ConnectionStep] {
        ConnectionPlanner.plan(
            action: action,
            displays: displays,
            allowsAffectedBuiltInDisconnect: override
        )
    }

    // MARK: - Action vocabulary

    func testActionRawValuesAndAllCases() {
        XCTAssertEqual(ConnectionAction.connectAll.rawValue, "connectAll")
        XCTAssertEqual(ConnectionAction.disconnectAllButMain.rawValue, "disconnectAllButMain")
        XCTAssertEqual(ConnectionAction.swapIdentical.rawValue, "swapIdentical")
        XCTAssertEqual(
            Set(ConnectionAction.allCases.map(\.rawValue)),
            ["connectAll", "disconnectAllButMain", "swapIdentical"]
        )
    }

    func testActionIsCodableRoundTrip() throws {
        for action in ConnectionAction.allCases {
            let data = try JSONEncoder().encode(action)
            let decoded = try JSONDecoder().decode(ConnectionAction.self, from: data)
            XCTAssertEqual(decoded, action)
        }
    }

    // MARK: - connectAll

    func testConnectAllEnablesOnlyOfflineDisplays() {
        let result = steps(.connectAll, [
            display(3, online: false),
            display(1, online: true),
            display(2, online: false),
        ])
        XCTAssertEqual(result.map(\.displayID), [2, 3])
        XCTAssertTrue(result.allSatisfy { $0.enable })
    }

    func testConnectAllWithAllOnlineReturnsEmpty() {
        let result = steps(.connectAll, [
            display(1, online: true),
            display(2, online: true),
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testConnectAllWithAllOfflineEnablesAllAscending() {
        let result = steps(.connectAll, [
            display(7, online: false),
            display(5, online: false),
            display(9, online: false),
        ])
        XCTAssertEqual(result.map(\.displayID), [5, 7, 9])
    }

    func testConnectAllOrdersByDisplayIDAscendingRegardlessOfInputOrder() {
        let shuffled = steps(.connectAll, [
            display(9, online: false),
            display(1, online: false),
            display(4, online: false),
            display(2, online: false),
        ])
        XCTAssertEqual(shuffled.map(\.displayID), [1, 2, 4, 9])
    }

    func testConnectAllIsDeterministicAcrossCalls() {
        let displays = [display(2, online: false), display(1, online: false), display(3, online: true)]
        XCTAssertEqual(steps(.connectAll, displays), steps(.connectAll, displays))
    }

    // MARK: - disconnectAllButMain

    func testDisconnectAllButMainDisablesOnlineNonMainExternal() {
        let result = steps(.disconnectAllButMain, [
            display(1, main: true),
            display(2, online: true),
            display(3, online: true),
        ])
        XCTAssertEqual(result.map(\.displayID), [2, 3])
        XCTAssertTrue(result.allSatisfy { !$0.enable })
    }

    func testDisconnectAllButMainKeepsMainDisplay() {
        let result = steps(.disconnectAllButMain, [
            display(1, main: true),
            display(2, online: true),
        ])
        XCTAssertFalse(result.contains { $0.displayID == 1 })
    }

    func testDisconnectAllButMainIgnoresOfflineDisplays() {
        let result = steps(.disconnectAllButMain, [
            display(1, main: true),
            display(2, online: true),
            display(3, online: false),
        ])
        XCTAssertEqual(result.map(\.displayID), [2])
    }

    func testDisconnectAllButMainWithoutOverrideNeverDisablesBuiltin() {
        let result = steps(.disconnectAllButMain, [
            display(1, main: true),
            display(2, online: true, builtin: false),
            display(3, online: true, builtin: true),
        ], override: false)
        // The built-in (3) is online and non-main, but the override is off —
        // the planner must fail closed and never emit a built-in disable.
        XCTAssertEqual(result.map(\.displayID), [2])
        XCTAssertFalse(result.contains { $0.displayID == 3 })
    }

    func testDisconnectAllButMainWithOverrideDisablesBuiltinNonMain() {
        let result = steps(.disconnectAllButMain, [
            display(1, main: true),
            display(2, online: true, builtin: false),
            display(3, online: true, builtin: true),
        ], override: true)
        XCTAssertEqual(result.map(\.displayID), [2, 3])
    }

    func testDisconnectAllButMainWithOverrideKeepsBuiltinMain() {
        let result = steps(.disconnectAllButMain, [
            display(1, builtin: true, main: true),
            display(2, online: true, builtin: false),
        ], override: true)
        // The built-in is the main display — it is kept regardless of override.
        XCTAssertFalse(result.contains { $0.displayID == 1 })
    }

    func testDisconnectAllButMainWithoutOverrideKeepsBuiltinMain() {
        let result = steps(.disconnectAllButMain, [
            display(1, builtin: true, main: true),
            display(2, online: true, builtin: false),
        ], override: false)
        XCTAssertEqual(result.map(\.displayID), [2])
    }

    func testDisconnectAllButMainRefusesWithoutMainDisplay() {
        let result = steps(.disconnectAllButMain, [
            display(1, online: true),
            display(2, online: true),
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testDisconnectAllButMainRefusesWithoutMainEvenWithOverrideOn() {
        let result = steps(.disconnectAllButMain, [
            display(1, online: true, builtin: true),
        ], override: true)
        XCTAssertTrue(result.isEmpty)
    }

    func testDisconnectAllButMainReturnsEmptyWhenOnlyMainOnline() {
        let result = steps(.disconnectAllButMain, [display(1, main: true)])
        XCTAssertTrue(result.isEmpty)
    }

    func testDisconnectAllButMainOrdersByDisplayIDAscending() {
        let result = steps(.disconnectAllButMain, [
            display(1, main: true),
            display(9, online: true),
            display(4, online: true),
            display(6, online: true),
        ])
        XCTAssertEqual(result.map(\.displayID), [4, 6, 9])
    }

    // MARK: - swapIdentical

    func testSwapIdenticalSwapsOnlineAndOfflinePair() {
        let result = steps(.swapIdentical, [
            display(1, online: true, vendor: 0x10, model: 0x20, serial: 111),
            display(2, online: false, vendor: 0x10, model: 0x20, serial: 222),
        ])
        XCTAssertEqual(result, [
            ConnectionStep(displayID: 1, enable: false, reason: result[0].reason),
            ConnectionStep(displayID: 2, enable: true, reason: result[1].reason),
        ])
        XCTAssertEqual(result.map(\.enable), [false, true])
    }

    func testSwapIdenticalIgnoresSerialInIdentity() {
        let result = steps(.swapIdentical, [
            display(1, online: true, vendor: 0xAA, model: 0xBB, serial: 1),
            display(2, online: false, vendor: 0xAA, model: 0xBB, serial: 999),
        ])
        XCTAssertEqual(result.count, 2)
    }

    func testSwapIdenticalRefusesOnThreeIdenticalDisplays() {
        let result = steps(.swapIdentical, [
            display(1, online: true, vendor: 0x10, model: 0x20),
            display(2, online: false, vendor: 0x10, model: 0x20),
            display(3, online: false, vendor: 0x10, model: 0x20),
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testSwapIdenticalReturnsEmptyForSingleDisplay() {
        let result = steps(.swapIdentical, [display(1)])
        XCTAssertTrue(result.isEmpty)
    }

    func testSwapIdenticalReturnsEmptyForDistinctDisplays() {
        let result = steps(.swapIdentical, [
            display(1, online: true, vendor: 0x10, model: 0x20),
            display(2, online: false, vendor: 0x10, model: 0x21),
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testSwapIdenticalRefusesOnTwoSeparateIdenticalPairs() {
        let result = steps(.swapIdentical, [
            display(1, online: true, vendor: 0x10, model: 0x20),
            display(2, online: false, vendor: 0x10, model: 0x20),
            display(3, online: true, vendor: 0x30, model: 0x40),
            display(4, online: false, vendor: 0x30, model: 0x40),
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testSwapIdenticalBothOnlineCyclesOneDisplaySameID() {
        let result = steps(.swapIdentical, [
            display(1, online: true, vendor: 0x10, model: 0x20),
            display(2, online: true, vendor: 0x10, model: 0x20),
        ])
        // Degenerate case: cycle a single member (never disable both).
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].displayID, result[1].displayID)
        XCTAssertEqual(result.map(\.enable), [false, true])
    }

    func testSwapIdenticalOrderingIsInputOrderIndependent() {
        let forward = steps(.swapIdentical, [
            display(1, online: true, vendor: 0x10, model: 0x20),
            display(2, online: false, vendor: 0x10, model: 0x20),
        ])
        let reversed = steps(.swapIdentical, [
            display(2, online: false, vendor: 0x10, model: 0x20),
            display(1, online: true, vendor: 0x10, model: 0x20),
        ])
        XCTAssertEqual(forward, reversed)
    }

    // MARK: - Cross-cutting invariants

    func testEveryStepCarriesANonEmptyReason() {
        let batches: [[ConnectionStep]] = [
            steps(.connectAll, [display(1, online: false)]),
            steps(.disconnectAllButMain, [display(1, main: true), display(2, online: true)]),
            steps(.swapIdentical, [
                display(1, online: true, vendor: 1, model: 2),
                display(2, online: false, vendor: 1, model: 2),
            ]),
        ]
        let all = batches.flatMap { $0 }
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.allSatisfy { !$0.reason.isEmpty })
    }

    func testPlanIsTotalForAllActionsOnEmptyInput() {
        for action in ConnectionAction.allCases {
            XCTAssertTrue(steps(action, []).isEmpty)
        }
    }
}
