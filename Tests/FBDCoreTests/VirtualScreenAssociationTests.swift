import XCTest
@testable import FBDCore

/// Row #21: associating a virtual screen with real displays, and recalling an
/// arrangement when it attaches.
///
/// ADR-0001 is why these are unit tests rather than a live check: a virtual screen
/// FBD creates does not appear in its own process's display list, so the case that
/// matters most — "the screen attached, arrange the displays" — cannot be produced
/// on demand here. The decision and the resolution are pure for exactly that reason.
final class VirtualScreenAssociationTests: XCTestCase {
    private let suiteName = "test.fbd.vscreen.associations"
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

    private func association(_ id: String, _ placements: [(String, Int32, Int32)]) -> VirtualScreenAssociation {
        VirtualScreenAssociation(
            virtualScreenID: id,
            placements: placements.map { .init(identity: $0.0, x: $0.1, y: $0.2) }
        )
    }

    // MARK: - The decision

    func testNoAssociationMeansNothingStored() {
        XCTAssertEqual(
            VirtualScreenAssociations.order(for: "screen-1", associations: [], attachedIdentities: ["a"]),
            .nothingStored
        )
    }

    /// An association with no placements is the same as none: arranging an empty set
    /// is not a thing that can happen, and reporting `arrange([])` would imply it is.
    func testAnEmptyAssociationIsTreatedAsNothingStored() {
        let stored = [association("screen-1", [])]
        XCTAssertEqual(
            VirtualScreenAssociations.order(for: "screen-1", associations: stored, attachedIdentities: ["a"]),
            .nothingStored
        )
    }

    func testArrangesWhenEveryAssociatedDisplayIsAttached() {
        let stored = [association("screen-1", [("a", 0, 0), ("b", 1920, 0)])]
        XCTAssertEqual(
            VirtualScreenAssociations.order(
                for: "screen-1", associations: stored, attachedIdentities: ["b", "a"]
            ),
            .arrange([.init(identity: "a", x: 0, y: 0), .init(identity: "b", x: 1920, y: 0)])
        )
    }

    /// The fail-closed case: a partial arrangement would move the displays that *are*
    /// here into positions chosen for a layout that is not.
    func testWaitsWhenAnAssociatedDisplayIsMissing() {
        let stored = [association("screen-1", [("a", 0, 0), ("b", 1920, 0)])]
        XCTAssertEqual(
            VirtualScreenAssociations.order(for: "screen-1", associations: stored, attachedIdentities: ["a"]),
            .waitingForDisplays(missing: ["b"])
        )
    }

    func testMissingDisplaysAreAllReported() {
        let stored = [association("screen-1", [("a", 0, 0), ("b", 1, 0), ("c", 2, 0)])]
        XCTAssertEqual(
            VirtualScreenAssociations.order(for: "screen-1", associations: stored, attachedIdentities: []),
            .waitingForDisplays(missing: ["a", "b", "c"])
        )
    }

    func testAnotherScreensAssociationIsNotUsed() {
        let stored = [association("screen-2", [("a", 0, 0)])]
        XCTAssertEqual(
            VirtualScreenAssociations.order(for: "screen-1", associations: stored, attachedIdentities: ["a"]),
            .nothingStored
        )
    }

    // MARK: - Resolving placements to anchors

    func testPlacementsResolveToTheAttachedDisplaysAnchors() {
        let placements = [
            VirtualScreenAssociation.Placement(identity: "a", x: 0, y: 0),
            VirtualScreenAssociation.Placement(identity: "b", x: 1920, y: 0),
        ]
        let anchors = VirtualScreenAssociations.anchors(
            for: placements,
            attached: [(identity: "a", displayID: 7), (identity: "b", displayID: 9)]
        )
        XCTAssertEqual(anchors, [LayoutAnchor(displayID: 7, x: 0, y: 0), LayoutAnchor(displayID: 9, x: 1920, y: 0)])
    }

    func testResolutionIsByIdentityNotByPositionInTheList() {
        // The same placements, with the attached displays listed the other way round:
        // the anchors must follow the identities, not the order they arrived in.
        let placements = [
            VirtualScreenAssociation.Placement(identity: "b", x: 1920, y: 0),
            VirtualScreenAssociation.Placement(identity: "a", x: 0, y: 0),
        ]
        let anchors = VirtualScreenAssociations.anchors(
            for: placements,
            attached: [(identity: "a", displayID: 7), (identity: "b", displayID: 9)]
        )
        XCTAssertEqual(anchors, [LayoutAnchor(displayID: 9, x: 1920, y: 0), LayoutAnchor(displayID: 7, x: 0, y: 0)])
    }

    func testAnUnresolvableIdentityYieldsNoAnchorsAtAll() {
        let placements = [
            VirtualScreenAssociation.Placement(identity: "a", x: 0, y: 0),
            VirtualScreenAssociation.Placement(identity: "gone", x: 1920, y: 0),
        ]
        XCTAssertNil(
            VirtualScreenAssociations.anchors(for: placements, attached: [(identity: "a", displayID: 7)]),
            "a half-resolved arrangement would move one display and leave the other"
        )
    }

    func testEmptyPlacementsYieldNoAnchors() {
        XCTAssertNil(VirtualScreenAssociations.anchors(for: [], attached: [(identity: "a", displayID: 7)]))
    }

    /// Two attached displays claiming one identity is a pathological case, but the
    /// answer must not depend on dictionary ordering.
    func testTwoDisplaysSharingAnIdentityResolveDeterministically() {
        let placements = [VirtualScreenAssociation.Placement(identity: "a", x: 0, y: 0)]
        let first = VirtualScreenAssociations.anchors(
            for: placements,
            attached: [(identity: "a", displayID: 7), (identity: "a", displayID: 9)]
        )
        let second = VirtualScreenAssociations.anchors(
            for: placements,
            attached: [(identity: "a", displayID: 7), (identity: "a", displayID: 9)]
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.first?.displayID, 7, "the first attached display wins")
    }

    // MARK: - Persistence

    func testRoundTripThroughTheInjectedSuite() {
        let stored = [
            association("screen-1", [("a", 0, 0), ("b", 1920, 0)]),
            association("screen-2", [("c", -1080, 0)]),
        ]
        Settings.saveVirtualScreenAssociations(stored, in: defaults)
        XCTAssertEqual(Settings.loadVirtualScreenAssociations(in: defaults), stored)
    }

    func testNothingStoredReadsAsEmpty() {
        XCTAssertTrue(Settings.loadVirtualScreenAssociations(in: defaults).isEmpty)
    }

    func testCorruptStoredDataReadsAsEmptyRatherThanTrapping() {
        defaults.set(Data("not json".utf8), forKey: "virtualScreenAssociations.v1")
        XCTAssertTrue(Settings.loadVirtualScreenAssociations(in: defaults).isEmpty)
    }

    /// Saving none clears the key rather than leaving an empty blob, so a later read
    /// cannot report "stored nothing" for the wrong reason.
    func testSavingNoneClearsTheStoredBlob() {
        Settings.saveVirtualScreenAssociations([association("screen-1", [("a", 0, 0)])], in: defaults)
        Settings.saveVirtualScreenAssociations([], in: defaults)
        XCTAssertNil(defaults.data(forKey: "virtualScreenAssociations.v1"))
        XCTAssertTrue(Settings.loadVirtualScreenAssociations(in: defaults).isEmpty)
    }
}
