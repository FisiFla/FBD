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
}
