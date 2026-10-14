import CoreGraphics
import XCTest
@testable import FBDCore

/// Pure unit tests for the group-sync decision logic: activation policies, the
/// nits-matching planner, and the per-group persistence accessors. Nothing here
/// touches a real display — every input is a plain value.
final class GroupSyncPolicyTests: XCTestCase {
    /// Scratch suite so tests never touch the real FBD domain.
    private let suiteName = "test.fbd.groupSync"

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    // MARK: - GroupActivationPolicy shape

    func testPolicyHasExactlyTheFiveBetterDisplayCases() {
        XCTAssertEqual(GroupActivationPolicy.allCases.count, 5)
        XCTAssertEqual(
            Set(GroupActivationPolicy.allCases.map(\.rawValue)),
            [
                "always",
                "allMembersPresent",
                "anyMembersPresent",
                "anyTwoMembersPresent",
                "anySyncSourceWithTargetMembersPresent",
            ]
        )
    }

    func testPolicyCodableRoundTrips() throws {
        let data = try JSONEncoder().encode(GroupActivationPolicy.anySyncSourceWithTargetMembersPresent)
        XCTAssertEqual(
            try JSONDecoder().decode(GroupActivationPolicy.self, from: data),
            .anySyncSourceWithTargetMembersPresent
        )
    }

    // MARK: - .always

    func testAlwaysIsActiveEvenWhenNothingIsConnected() {
        let policy = GroupActivationPolicy.always
        XCTAssertTrue(policy.isActive(memberIDs: [], connectedIDs: [], syncSourceIDs: [], syncTargetIDs: []))
        XCTAssertTrue(policy.isActive(memberIDs: [1, 2], connectedIDs: [], syncSourceIDs: [], syncTargetIDs: []))
        XCTAssertTrue(policy.isActive(memberIDs: [1], connectedIDs: [1], syncSourceIDs: [], syncTargetIDs: []))
    }

    // MARK: - .allMembersPresent

    func testAllMembersPresentRequiresEveryMember() {
        let policy = GroupActivationPolicy.allMembersPresent
        // All present (extra connected displays are irrelevant).
        XCTAssertTrue(policy.isActive(memberIDs: [1, 2], connectedIDs: [1, 2, 3], syncSourceIDs: [], syncTargetIDs: []))
        // One missing.
        XCTAssertFalse(policy.isActive(memberIDs: [1, 2], connectedIDs: [1], syncSourceIDs: [], syncTargetIDs: []))
        // None present.
        XCTAssertFalse(policy.isActive(memberIDs: [1, 2], connectedIDs: [], syncSourceIDs: [], syncTargetIDs: []))
        // Empty group is inactive (nothing to sync).
        XCTAssertFalse(policy.isActive(memberIDs: [], connectedIDs: [1], syncSourceIDs: [], syncTargetIDs: []))
    }

    // MARK: - .anyMembersPresent

    func testAnyMembersPresentNeedsAtLeastOne() {
        let policy = GroupActivationPolicy.anyMembersPresent
        XCTAssertTrue(policy.isActive(memberIDs: [1, 2, 3], connectedIDs: [2], syncSourceIDs: [], syncTargetIDs: []))
        XCTAssertTrue(policy.isActive(memberIDs: [1, 2], connectedIDs: [1, 2], syncSourceIDs: [], syncTargetIDs: []))
        XCTAssertFalse(policy.isActive(memberIDs: [1, 2], connectedIDs: [], syncSourceIDs: [], syncTargetIDs: []))
        XCTAssertFalse(policy.isActive(memberIDs: [1, 2], connectedIDs: [9], syncSourceIDs: [], syncTargetIDs: []))
    }

    // MARK: - .anyTwoMembersPresent

    func testAnyTwoMembersPresentNeedsTwo() {
        let policy = GroupActivationPolicy.anyTwoMembersPresent
        XCTAssertTrue(policy.isActive(memberIDs: [1, 2, 3], connectedIDs: [1, 3], syncSourceIDs: [], syncTargetIDs: []))
        XCTAssertTrue(policy.isActive(memberIDs: [1, 2], connectedIDs: [1, 2], syncSourceIDs: [], syncTargetIDs: []))
        XCTAssertFalse(policy.isActive(memberIDs: [1, 2], connectedIDs: [1], syncSourceIDs: [], syncTargetIDs: []))
        XCTAssertFalse(policy.isActive(memberIDs: [1], connectedIDs: [1], syncSourceIDs: [], syncTargetIDs: []))
        XCTAssertFalse(policy.isActive(memberIDs: [1, 2], connectedIDs: [], syncSourceIDs: [], syncTargetIDs: []))
    }

    // MARK: - .anySyncSourceWithTargetMembersPresent

    func testSyncSourceWithTargetActiveWhenBothRolesPresent() {
        let policy = GroupActivationPolicy.anySyncSourceWithTargetMembersPresent
        XCTAssertTrue(
            policy.isActive(memberIDs: [1, 2], connectedIDs: [1, 2], syncSourceIDs: [1], syncTargetIDs: [2])
        )
        // Source and target may be covered by different present displays.
        XCTAssertTrue(
            policy.isActive(memberIDs: [1, 2, 3], connectedIDs: [2, 3], syncSourceIDs: [1, 2], syncTargetIDs: [3])
        )
    }

    func testSyncSourceWithTargetInactiveWhenOnlySourcePresent() {
        let policy = GroupActivationPolicy.anySyncSourceWithTargetMembersPresent
        XCTAssertFalse(
            policy.isActive(memberIDs: [1, 2], connectedIDs: [1], syncSourceIDs: [1], syncTargetIDs: [2])
        )
    }

    func testSyncSourceWithTargetInactiveWhenOnlyTargetPresent() {
        let policy = GroupActivationPolicy.anySyncSourceWithTargetMembersPresent
        XCTAssertFalse(
            policy.isActive(memberIDs: [1, 2], connectedIDs: [2], syncSourceIDs: [1], syncTargetIDs: [2])
        )
    }

    func testSyncSourceWithTargetTreatsEmptyFiltersAsAllMembers() {
        let policy = GroupActivationPolicy.anySyncSourceWithTargetMembersPresent
        // With no filters every member is both a source and a target, so a single
        // present member satisfies both roles.
        XCTAssertTrue(policy.isActive(memberIDs: [1, 2], connectedIDs: [2], syncSourceIDs: [], syncTargetIDs: []))
        // Nothing present still cannot satisfy either role.
        XCTAssertFalse(policy.isActive(memberIDs: [1, 2], connectedIDs: [], syncSourceIDs: [], syncTargetIDs: []))
    }

    // MARK: - Planner: membership

    func testPlanWritesEveryConnectedMemberInMemberOrder() {
        let request = GroupSyncRequest(members: [3, 1, 2], connectedIDs: [1, 2, 3], value: 0.5)
        let plan = GroupSyncPlanner.plan(request)
        XCTAssertEqual(plan.writes.map(\.displayID), [3, 1, 2])
        XCTAssertEqual(plan.writes.map(\.value), [0.5, 0.5, 0.5])
    }

    func testPlanExcludesDisconnectedMembers() {
        let request = GroupSyncRequest(members: [1, 2, 3], connectedIDs: [1, 3], value: 0.4)
        XCTAssertEqual(GroupSyncPlanner.plan(request).writes.map(\.displayID), [1, 3])
    }

    func testPlanIsEmptyWhenNoMemberIsConnected() {
        let request = GroupSyncRequest(members: [1, 2], connectedIDs: [], value: 0.5)
        XCTAssertTrue(GroupSyncPlanner.plan(request).isEmpty)
    }

    func testPlanIsEmptyForAnEmptyGroup() {
        let request = GroupSyncRequest(members: [], connectedIDs: [1, 2], value: 0.5)
        XCTAssertTrue(GroupSyncPlanner.plan(request).isEmpty)
    }

    // MARK: - Planner: virtual screens

    func testPlanExcludesVirtualScreensByDefault() {
        let request = GroupSyncRequest(members: [1, 2], connectedIDs: [1, 2], virtualDisplayIDs: [2], value: 0.3)
        XCTAssertEqual(GroupSyncPlanner.plan(request).writes.map(\.displayID), [1])
    }

    func testPlanIncludesVirtualScreensWhenAllowed() {
        let request = GroupSyncRequest(
            members: [1, 2],
            connectedIDs: [1, 2],
            virtualDisplayIDs: [2],
            includeVirtualScreens: true,
            value: 0.3
        )
        XCTAssertEqual(GroupSyncPlanner.plan(request).writes.map(\.displayID), [1, 2])
    }

    // MARK: - Planner: source / target filters

    func testPlanTargetFilterWritesOnlyListedTargets() {
        let request = GroupSyncRequest(members: [1, 2, 3], connectedIDs: [1, 2, 3], syncTargetIDs: [2, 3], value: 0.5)
        XCTAssertEqual(GroupSyncPlanner.plan(request).writes.map(\.displayID), [2, 3])
    }

    func testPlanTargetFilterExcludesUnlistedMembers() {
        // Only display 2 is a target: 1 and 3 are excluded even though connected.
        let request = GroupSyncRequest(members: [1, 2, 3], connectedIDs: [1, 2, 3], syncTargetIDs: [2], value: 0.5)
        let written = GroupSyncPlanner.plan(request).writes.map(\.displayID)
        XCTAssertEqual(written, [2])
        XCTAssertFalse(written.contains(1))
        XCTAssertFalse(written.contains(3))
    }

    func testPlanHonoursSourceFilterWhenChoosingTheSource() {
        // Display 1 is a 1000-nit panel, display 2 a 500-nit panel.
        let ceilings: [CGDirectDisplayID: Int] = [1: 1000, 2: 500]
        // No source filter → the first member (1, 1000-nit) drives: 0.5 → 500 nits
        // → 0.5 on panel 1 (1000 nits) and 1.0 on panel 2 (500 nits).
        let unfiltered = GroupSyncRequest(members: [1, 2], connectedIDs: [1, 2], targetCeilingNits: ceilings, value: 0.5)
        XCTAssertEqual(GroupSyncPlanner.plan(unfiltered).writes.map(\.value), [0.5, 1.0])

        // Only display 2 may be a source → the 500-nit panel drives: 0.5 → 250 nits
        // → 0.25 on panel 1 and 0.5 on panel 2.
        let filtered = GroupSyncRequest(
            members: [1, 2],
            connectedIDs: [1, 2],
            syncSourceIDs: [2],
            targetCeilingNits: ceilings,
            value: 0.5
        )
        XCTAssertEqual(GroupSyncPlanner.plan(filtered).writes.map(\.value), [0.25, 0.5])
    }

    func testPlanFallsBackToFirstEligibleSourceWhenReferenceIsNotAMember() {
        let request = GroupSyncRequest(
            members: [1, 2],
            connectedIDs: [1, 2],
            sourceDisplayID: 99,
            targetCeilingNits: [1: 1000, 2: 500],
            value: 0.5
        )
        XCTAssertEqual(GroupSyncPlanner.plan(request).writes.map(\.value), [0.5, 1.0])
    }

    func testPlanIsEmptyWhenNoEligibleSourceIsConnected() {
        // The only permitted source (1) is offline.
        let request = GroupSyncRequest(members: [1, 2], connectedIDs: [2], syncSourceIDs: [1], value: 0.5)
        XCTAssertTrue(GroupSyncPlanner.plan(request).isEmpty)
    }

    // MARK: - Planner: nits matching

    func testPlanMatchesBrightnessSyncHelperExactly() {
        let request = GroupSyncRequest(
            members: [1, 2],
            connectedIDs: [1, 2],
            targetCeilingNits: [1: 1600, 2: 500],
            value: 0.6
        )
        let writes = GroupSyncPlanner.plan(request).writes
        let expected = BrightnessSync.equivalentValue(0.6, sourceCeilingNits: 1600, targetCeilingNits: 500)
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[1].value, expected, accuracy: 0.0001)
    }

    func testNitsMatchingIsMonotonicInTheSourceValue() {
        let ceilings: [CGDirectDisplayID: Int] = [1: 1000, 2: 600]
        let low = GroupSyncRequest(members: [1, 2], connectedIDs: [1, 2], targetCeilingNits: ceilings, value: 0.2)
        let high = GroupSyncRequest(members: [1, 2], connectedIDs: [1, 2], targetCeilingNits: ceilings, value: 0.8)
        let lowWrites = GroupSyncPlanner.plan(low).writes
        let highWrites = GroupSyncPlanner.plan(high).writes
        XCTAssertEqual(lowWrites.count, highWrites.count)
        for (a, b) in zip(lowWrites, highWrites) {
            XCTAssertLessThan(a.value, b.value)
        }
    }

    func testNitsMatchingStaysWithinUnitRangeWhenClamped() {
        // A bright source (1600 nits) onto a dim target (100 nits) would need a
        // 16× value, which must clamp to 1 rather than overshoot.
        let request = GroupSyncRequest(
            members: [1, 2],
            connectedIDs: [1, 2],
            targetCeilingNits: [1: 1600, 2: 100],
            value: 1.0
        )
        for write in GroupSyncPlanner.plan(request).writes {
            XCTAssertGreaterThanOrEqual(write.value, 0)
            XCTAssertLessThanOrEqual(write.value, 1)
        }
    }

    func testPlanClampsAnOutOfRangeSourceValue() {
        let request = GroupSyncRequest(members: [1], connectedIDs: [1], value: 2.0)
        XCTAssertEqual(GroupSyncPlanner.plan(request).writes.map(\.value), [1.0])
    }

    func testRawModeCopiesTheValueUnchangedAcrossCeilings() {
        let request = GroupSyncRequest(
            members: [1, 2],
            connectedIDs: [1, 2],
            targetCeilingNits: [1: 1000, 2: 500],
            value: 0.4,
            matchBrightnessInNits: false
        )
        XCTAssertEqual(GroupSyncPlanner.plan(request).writes.map(\.value), [0.4, 0.4])
    }

    func testPlanEquatable() {
        let plan = GroupSyncPlan(writes: [.init(displayID: 1, value: 0.5)])
        XCTAssertEqual(plan, GroupSyncPlan(writes: [.init(displayID: 1, value: 0.5)]))
        XCTAssertNotEqual(plan, GroupSyncPlan(writes: [.init(displayID: 2, value: 0.5)]))
        XCTAssertNotEqual(plan, GroupSyncPlan(writes: []))
    }

    // MARK: - Persistence accessors

    func testStoreDefaultsToEnabledTrue() {
        XCTAssertTrue(GroupSyncStore.isEnabled(groupID: "g1", defaults: makeDefaults()))
    }

    func testStoreEnabledRoundTripsPerGroup() {
        let defaults = makeDefaults()
        GroupSyncStore.setEnabled(false, groupID: "g1", defaults: defaults)
        XCTAssertFalse(GroupSyncStore.isEnabled(groupID: "g1", defaults: defaults))
        // A different group keeps the default.
        XCTAssertTrue(GroupSyncStore.isEnabled(groupID: "g2", defaults: defaults))
    }

    func testStoreActivationPolicyDefaultsToAlways() {
        XCTAssertEqual(GroupSyncStore.activationPolicy(groupID: "g1", defaults: makeDefaults()), .always)
    }

    func testStoreActivationPolicyRoundTrips() {
        let defaults = makeDefaults()
        GroupSyncStore.setActivationPolicy(.anyTwoMembersPresent, groupID: "g1", defaults: defaults)
        XCTAssertEqual(GroupSyncStore.activationPolicy(groupID: "g1", defaults: defaults), .anyTwoMembersPresent)
        // A different group keeps the default.
        XCTAssertEqual(GroupSyncStore.activationPolicy(groupID: "g2", defaults: defaults), .always)
    }

    func testStoreSourceAndTargetFiltersRoundTrip() {
        let defaults = makeDefaults()
        GroupSyncStore.setSyncSourceIDs([3, 1], groupID: "g1", defaults: defaults)
        GroupSyncStore.setSyncTargetIDs([2], groupID: "g1", defaults: defaults)
        XCTAssertEqual(GroupSyncStore.syncSourceIDs(groupID: "g1", defaults: defaults), [1, 3])
        XCTAssertEqual(GroupSyncStore.syncTargetIDs(groupID: "g1", defaults: defaults), [2])
        XCTAssertTrue(GroupSyncStore.syncSourceIDs(groupID: "g2", defaults: defaults).isEmpty)
        XCTAssertTrue(GroupSyncStore.syncTargetIDs(groupID: "g2", defaults: defaults).isEmpty)
    }

    func testStoreIncludeVirtualScreensDefaultsFalseAndRoundTrips() {
        let defaults = makeDefaults()
        XCTAssertFalse(GroupSyncStore.includeVirtualScreens(groupID: "g1", defaults: defaults))
        GroupSyncStore.setIncludeVirtualScreens(true, groupID: "g1", defaults: defaults)
        XCTAssertTrue(GroupSyncStore.includeVirtualScreens(groupID: "g1", defaults: defaults))
    }
}
