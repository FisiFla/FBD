import CoreGraphics
import Foundation
import XCTest
@testable import FBDCore

/// `syncValue` is the pure half of "Sync now": it decides which member's
/// brightness a group sync should propagate from. Keeping it pure is what makes
/// it testable with no display attached and no DDC read.
final class DisplayGroupsSyncValueTests: XCTestCase {
    private let suiteName = "test.fbd.groupsyncvalue"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// A controller holding one group containing `displayIDs`.
    private func makeGroup(_ displayIDs: [CGDirectDisplayID]) throws -> (DisplayGroupsController, String) {
        let controller = DisplayGroupsController(defaults: defaults)
        controller.createGroup(name: "Test group")
        let id = try XCTUnwrap(controller.groups.first?.id)
        for displayID in displayIDs {
            controller.addDisplay(displayID, toGroup: id)
        }
        return (controller, id)
    }

    func testReturnsTheFirstConnectedMembersBrightness() throws {
        let (controller, id) = try makeGroup([10, 20])
        let reading = controller.syncValue(inGroup: id, connectedIDs: [10, 20]) { displayID in
            displayID == 10 ? 0.42 : 0.9
        }
        let unwrapped = try XCTUnwrap(reading)
        XCTAssertEqual(unwrapped.value, 0.42, accuracy: 0.0001)
        XCTAssertEqual(unwrapped.sourceDisplayID, 10)
    }

    /// The source must be the member the value actually came from, otherwise the
    /// plan's luminance matching would convert from the wrong panel.
    func testSkipsADisconnectedFirstMember() throws {
        let (controller, id) = try makeGroup([10, 20])
        let reading = controller.syncValue(inGroup: id, connectedIDs: [20]) { displayID in
            displayID == 20 ? 0.3 : nil
        }
        let unwrapped = try XCTUnwrap(reading)
        XCTAssertEqual(unwrapped.value, 0.3, accuracy: 0.0001)
        XCTAssertEqual(unwrapped.sourceDisplayID, 20)
    }

    func testIsNilWhenTheGroupIsDisabled() throws {
        let (controller, id) = try makeGroup([10, 20])
        controller.setEnabled(false, forGroup: id)
        XCTAssertNil(controller.syncValue(inGroup: id, connectedIDs: [10, 20]) { _ in 0.5 })
    }

    func testIsNilWhenNoMemberIsConnected() throws {
        let (controller, id) = try makeGroup([10, 20])
        XCTAssertNil(controller.syncValue(inGroup: id, connectedIDs: []) { _ in 0.5 })
    }

    /// Never sync from a value that could not be read.
    func testIsNilWhenTheSourceHasNoBrightness() throws {
        let (controller, id) = try makeGroup([10])
        XCTAssertNil(controller.syncValue(inGroup: id, connectedIDs: [10]) { _ in nil })
    }

    func testIsNilForAnUnknownGroup() throws {
        let (controller, _) = try makeGroup([10])
        XCTAssertNil(controller.syncValue(inGroup: "no-such-group", connectedIDs: [10]) { _ in 0.5 })
    }

    /// One member alone is not a sync, but it is still a valid read — the caller
    /// decides whether that is useful.
    func testSingleMemberIsStillRead() throws {
        let (controller, id) = try makeGroup([77])
        let unwrapped = try XCTUnwrap(controller.syncValue(inGroup: id, connectedIDs: [77]) { _ in 0.25 })
        XCTAssertEqual(unwrapped.sourceDisplayID, 77)
        XCTAssertEqual(unwrapped.value, 0.25, accuracy: 0.0001)
    }
}
