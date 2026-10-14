import CoreGraphics
import XCTest
@testable import FBDCore

final class DisplayGroupsControllerTests: XCTestCase {
    /// Scratch suite so tests never touch the real FBD domain.
    private let suiteName = "test.fbd.groups"

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController() -> DisplayGroupsController {
        let defaults = UserDefaults(suiteName: suiteName)!
        return DisplayGroupsController(defaults: defaults)
    }

    func testCreateGroupAppendsWithUniqueID() {
        let controller = makeController()
        controller.createGroup(name: "Office")
        controller.createGroup(name: "Studio")

        XCTAssertEqual(controller.groups.count, 2)
        XCTAssertEqual(controller.groups.map(\.name), ["Office", "Studio"])
        XCTAssertNotEqual(controller.groups[0].id, controller.groups[1].id)
    }

    func testDeleteGroupRemovesOnlyMatchingID() {
        let controller = makeController()
        controller.createGroup(name: "Office")
        controller.createGroup(name: "Studio")
        let officeID = controller.groups[0].id

        controller.deleteGroup(id: officeID)

        XCTAssertEqual(controller.groups.count, 1)
        XCTAssertEqual(controller.groups[0].name, "Studio")
        // Deleting an unknown id is a silent no-op.
        controller.deleteGroup(id: "does-not-exist")
        XCTAssertEqual(controller.groups.count, 1)
    }

    func testAddAndRemoveDisplayMembership() {
        let controller = makeController()
        controller.createGroup(name: "Office")
        let groupID = controller.groups[0].id
        let displayID: CGDirectDisplayID = 5

        controller.addDisplay(displayID, toGroup: groupID)
        XCTAssertEqual(controller.groups[0].displayIDs, [displayID])

        // Adding twice is idempotent.
        controller.addDisplay(displayID, toGroup: groupID)
        XCTAssertEqual(controller.groups[0].displayIDs.count, 1)

        controller.removeDisplay(displayID, fromGroup: groupID)
        XCTAssertTrue(controller.groups[0].displayIDs.isEmpty)

        // Unknown group is a silent no-op.
        controller.addDisplay(7, toGroup: "missing")
        XCTAssertEqual(controller.groups.count, 1)
    }

    func testPersistenceRoundTripAcrossInstances() {
        let first = makeController()
        first.createGroup(name: "Office", displayIDs: [1, 3, 5])
        first.createGroup(name: "Studio")

        // A fresh instance loads the same groups from the same suite — the
        // cross-process contract the app and CLI rely on.
        let second = makeController()
        XCTAssertEqual(second.groups.count, 2)
        XCTAssertEqual(second.groups.map(\.name), ["Office", "Studio"])
        XCTAssertEqual(second.groups[0].displayIDs, [1, 3, 5])
        // IDs survive the round trip (persisted, not regenerated).
        XCTAssertEqual(second.groups[0].id, first.groups[0].id)
    }

    func testCorruptStoredDataFallsBackToEmpty() {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(Data("not-json".utf8), forKey: "displayGroups.v1")

        let controller = makeController()
        XCTAssertTrue(controller.groups.isEmpty)
    }

    func testUsesProvidedDomainNotStandard() {
        // Groups must land in the injected suite, never UserDefaults.standard
        // (the pre-fix behavior split app and CLI state).
        let controller = makeController()
        controller.createGroup(name: "Isolated")

        XCTAssertNil(UserDefaults.standard.data(forKey: "displayGroups.v1"))
        XCTAssertNotNil(UserDefaults(suiteName: suiteName)?.data(forKey: "displayGroups.v1"))
    }

    // MARK: - Sync plan gating (pure: no display is ever touched)

    func testSyncPlanProducesWritesWhenEnabledAndActive() {
        let controller = makeController()
        controller.createGroup(name: "Office", displayIDs: [1, 2])
        let groupID = controller.groups[0].id

        // Defaults: enabled, `.always`, all-member sources/targets, nits matching.
        let plan = controller.syncPlan(
            inGroup: groupID,
            value: 0.5,
            connectedIDs: [1, 2],
            ceilingNits: { _ in 1000 }
        )
        XCTAssertEqual(plan.writes.map(\.displayID), [1, 2])
        XCTAssertEqual(plan.writes.map(\.value), [0.5, 0.5])
    }

    func testSyncPlanIsEmptyWhenGroupDisabled() {
        let controller = makeController()
        controller.createGroup(name: "Office", displayIDs: [1, 2])
        let groupID = controller.groups[0].id
        controller.setEnabled(false, forGroup: groupID)

        let plan = controller.syncPlan(
            inGroup: groupID,
            value: 0.5,
            connectedIDs: [1, 2],
            ceilingNits: { _ in 1000 }
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testSyncPlanIsEmptyWhenActivationPolicyIsInactive() {
        let controller = makeController()
        controller.createGroup(name: "Office", displayIDs: [1, 2])
        let groupID = controller.groups[0].id
        controller.setActivationPolicy(.allMembersPresent, forGroup: groupID)

        // Display 2 is offline → `allMembersPresent` is inactive → no-op.
        let plan = controller.syncPlan(
            inGroup: groupID,
            value: 0.5,
            connectedIDs: [1],
            ceilingNits: { _ in 1000 }
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testSyncPlanUnknownGroupIsEmpty() {
        let controller = makeController()
        let plan = controller.syncPlan(inGroup: "missing", value: 0.5, connectedIDs: [1], ceilingNits: { _ in 100 })
        XCTAssertTrue(plan.isEmpty)
    }

    func testSyncPlanExcludesVirtualScreensUnlessAllowed() {
        let controller = makeController()
        controller.createGroup(name: "Office", displayIDs: [1, 2])
        let groupID = controller.groups[0].id

        func plan() -> GroupSyncPlan {
            controller.syncPlan(
                inGroup: groupID,
                value: 0.5,
                connectedIDs: [1, 2],
                virtualDisplayIDs: [2],
                ceilingNits: { _ in 1000 }
            )
        }
        XCTAssertEqual(plan().writes.map(\.displayID), [1])
        controller.setIncludeVirtualScreens(true, forGroup: groupID)
        XCTAssertEqual(plan().writes.map(\.displayID), [1, 2])
    }

    func testSyncConfigurationPersistsAcrossInstances() {
        let first = makeController()
        first.createGroup(name: "Office", displayIDs: [1, 2])
        let groupID = first.groups[0].id
        first.setEnabled(false, forGroup: groupID)
        first.setActivationPolicy(.anyTwoMembersPresent, forGroup: groupID)
        first.setSyncSourceIDs([1], forGroup: groupID)
        first.setSyncTargetIDs([2], forGroup: groupID)
        first.setIncludeVirtualScreens(true, forGroup: groupID)

        let second = makeController()
        XCTAssertFalse(second.isEnabled(groupID: groupID))
        XCTAssertEqual(second.activationPolicy(forGroup: groupID), .anyTwoMembersPresent)
        XCTAssertEqual(second.syncSourceIDs(forGroup: groupID), [1])
        XCTAssertEqual(second.syncTargetIDs(forGroup: groupID), [2])
        XCTAssertTrue(second.includeVirtualScreens(forGroup: groupID))
    }

    func testTwoGroupsDoNotInterfere() {
        let controller = makeController()
        controller.createGroup(name: "A", displayIDs: [1])
        controller.createGroup(name: "B", displayIDs: [2])
        let a = controller.groups[0].id
        let b = controller.groups[1].id
        controller.setEnabled(false, forGroup: a)
        controller.setActivationPolicy(.allMembersPresent, forGroup: b)

        // Config is keyed per group.
        XCTAssertFalse(controller.isEnabled(groupID: a))
        XCTAssertTrue(controller.isEnabled(groupID: b))
        XCTAssertEqual(controller.activationPolicy(forGroup: a), .always)
        XCTAssertEqual(controller.activationPolicy(forGroup: b), .allMembersPresent)

        // A disabled group plans nothing; B (enabled, all present) plans its member.
        XCTAssertTrue(controller.syncPlan(inGroup: a, value: 0.5, connectedIDs: [1], ceilingNits: { _ in 100 }).isEmpty)
        XCTAssertEqual(
            controller.syncPlan(inGroup: b, value: 0.5, connectedIDs: [2], ceilingNits: { _ in 100 }).writes.map(\.displayID),
            [2]
        )
    }
}
