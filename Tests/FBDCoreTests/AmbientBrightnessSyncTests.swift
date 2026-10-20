import XCTest
@testable import FBDCore

/// The ambient-light sync (#30): an external display has no ambient sensor, so
/// it follows the built-in display's auto-brightness — through nits, because a
/// slider fraction means nothing across two panels with different ceilings.
final class AmbientBrightnessSyncTests: XCTestCase {
    private let suiteName = "test.fbd.ambient"

    // MARK: - Which displays follow

    /// The built-in panel and an external monitor, as the model sees them.
    private func makeDisplay(
        id: CGDirectDisplayID,
        isBuiltin: Bool,
        vendor: UInt32,
        model: UInt32,
        serial: UInt32
    ) -> Display {
        Display(
            id: id,
            name: "Display \(id)",
            isBuiltin: isBuiltin,
            vendorNumber: vendor,
            modelNumber: model,
            serialNumber: serial,
            bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            isOnline: true,
            isActive: true
        )
    }

    /// A display cannot follow itself.
    func testTheSourceIsNeverOneOfTheTargets() {
        let builtin = makeDisplay(id: 1, isBuiltin: true, vendor: 10, model: 20, serial: 30)
        let targets = AmbientBrightnessSync.targets(
            source: builtin,
            candidates: [builtin],
            followers: [builtin.identityKey]
        )
        XCTAssertTrue(targets.isEmpty)
    }

    /// A display the user did not opt in is never driven.
    func testOnlyTheOptedInDisplaysAreTargets() {
        let builtin = makeDisplay(id: 1, isBuiltin: true, vendor: 10, model: 20, serial: 30)
        let optedIn = makeDisplay(id: 2, isBuiltin: false, vendor: 11, model: 21, serial: 31)
        let other = makeDisplay(id: 3, isBuiltin: false, vendor: 12, model: 22, serial: 32)

        let targets = AmbientBrightnessSync.targets(
            source: builtin,
            candidates: [builtin, optedIn, other],
            followers: [optedIn.identityKey]
        )

        XCTAssertEqual(targets.map(\.id), [optedIn.id])
    }

    func testNoFollowersMeansNoTargets() {
        let builtin = makeDisplay(id: 1, isBuiltin: true, vendor: 10, model: 20, serial: 30)
        let external = makeDisplay(id: 2, isBuiltin: false, vendor: 11, model: 21, serial: 31)

        let targets = AmbientBrightnessSync.targets(
            source: builtin,
            candidates: [builtin, external],
            followers: []
        )

        XCTAssertTrue(targets.isEmpty)
    }

    // MARK: - The setting

    func testTheFollowersRoundTrip() {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(Settings.ambientSyncFollowers(in: defaults).isEmpty)

        Settings.setAmbientSyncFollowers(["a", "b"], in: defaults)
        XCTAssertEqual(Settings.ambientSyncFollowers(in: defaults), ["a", "b"])
        XCTAssertTrue(Settings.isAmbientSyncFollower("a", in: defaults))
        XCTAssertFalse(Settings.isAmbientSyncFollower("c", in: defaults))
    }

    func testTheFollowerListIsStoredAsJSON() {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        Settings.setAmbientSyncFollowers(["a"], in: defaults)

        let data = defaults.data(forKey: "ambientBrightnessSyncFollowers.v1")
        XCTAssertNotNil(data)
        XCTAssertEqual(try? JSONDecoder().decode([String].self, from: data!), ["a"])
    }

    func testOneDisplayCanBeOptedInAndOut() {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        Settings.setAmbientSyncFollower(true, for: "a", in: defaults)
        Settings.setAmbientSyncFollower(true, for: "b", in: defaults)
        XCTAssertEqual(Settings.ambientSyncFollowers(in: defaults).sorted(), ["a", "b"])

        Settings.setAmbientSyncFollower(false, for: "a", in: defaults)
        XCTAssertEqual(Settings.ambientSyncFollowers(in: defaults), ["b"])
    }

    func testOptingInTwiceDoesNotDuplicateTheDisplay() {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        Settings.setAmbientSyncFollower(true, for: "a", in: defaults)
        Settings.setAmbientSyncFollower(true, for: "a", in: defaults)
        XCTAssertEqual(Settings.ambientSyncFollowers(in: defaults), ["a"])
    }

    // MARK: - The mapping

    func testTheSameCeilingKeepsTheFraction() {
        let fraction = AmbientBrightnessSync.targetFraction(
            sourceFraction: 0.4,
            sourceCeilingNits: 300,
            targetCeilingNits: 300
        )
        XCTAssertEqual(fraction ?? .nan, 0.4, accuracy: 0.0001)
    }

    /// The source's luminance is what is carried over: a 600-nit panel at 50 %
    /// asks for 300 nits, which is the whole scale of a 300-nit panel.
    func testTheLuminanceIsCarriedOver() {
        let fraction = AmbientBrightnessSync.targetFraction(
            sourceFraction: 0.5,
            sourceCeilingNits: 600,
            targetCeilingNits: 300
        )
        XCTAssertEqual(fraction ?? .nan, 1.0, accuracy: 0.0001)
    }

    func testADimmerSourceAsksForLessOfTheTarget() {
        let fraction = AmbientBrightnessSync.targetFraction(
            sourceFraction: 0.25,
            sourceCeilingNits: 600,
            targetCeilingNits: 300
        )
        XCTAssertEqual(fraction ?? .nan, 0.5, accuracy: 0.0001)
    }

    /// A brighter panel asks for more light than the target can give: the
    /// target is asked for all of it, never for a value outside its scale.
    func testTheTargetIsClampedToItsOwnScale() {
        let fraction = AmbientBrightnessSync.targetFraction(
            sourceFraction: 1.0,
            sourceCeilingNits: 1600,
            targetCeilingNits: 300
        )
        XCTAssertEqual(fraction ?? .nan, 1.0, accuracy: 0.0001)
    }

    func testTheSourceFractionIsClamped() {
        let high = AmbientBrightnessSync.targetFraction(
            sourceFraction: 4,
            sourceCeilingNits: 300,
            targetCeilingNits: 300
        )
        XCTAssertEqual(high ?? .nan, 1.0, accuracy: 0.0001)

        let low = AmbientBrightnessSync.targetFraction(
            sourceFraction: -1,
            sourceCeilingNits: 300,
            targetCeilingNits: 300
        )
        XCTAssertEqual(low ?? .nan, 0.0, accuracy: 0.0001)
    }

    // MARK: - Unknown ceilings

    /// The mapping is a division: a display whose luminance could not be read
    /// must not be driven by a guess.
    func testAnUnknownSourceCeilingHasNoAnswer() {
        XCTAssertNil(
            AmbientBrightnessSync.targetFraction(
                sourceFraction: 0.5,
                sourceCeilingNits: nil,
                targetCeilingNits: 300
            )
        )
    }

    func testAnUnknownTargetCeilingHasNoAnswer() {
        XCTAssertNil(
            AmbientBrightnessSync.targetFraction(
                sourceFraction: 0.5,
                sourceCeilingNits: 300,
                targetCeilingNits: nil
            )
        )
    }

    /// A ceiling of zero means *unknown*, not *black*.
    func testAZeroCeilingIsUnknownRatherThanBlack() {
        XCTAssertNil(
            AmbientBrightnessSync.targetFraction(
                sourceFraction: 0.5,
                sourceCeilingNits: 0,
                targetCeilingNits: 300
            )
        )
        XCTAssertNil(
            AmbientBrightnessSync.targetFraction(
                sourceFraction: 0.5,
                sourceCeilingNits: 300,
                targetCeilingNits: 0
            )
        )
    }

    // MARK: - Whether a write is worth it

    func testAWriteIsSkippedWhenTheTargetIsAlreadyThere() {
        XCTAssertFalse(AmbientBrightnessSync.shouldWrite(current: 0.5, target: 0.51))
    }

    func testAWriteHappensWhenTheTargetIsFarEnoughAway() {
        XCTAssertTrue(AmbientBrightnessSync.shouldWrite(current: 0.5, target: 0.6))
    }

    /// A missing reading is not a reason to skip the request.
    func testAWriteHappensWhenTheCurrentValueIsUnknown() {
        XCTAssertTrue(AmbientBrightnessSync.shouldWrite(current: nil, target: 0.5))
    }

    func testTheEpsilonCanBeWidened() {
        // A wider epsilon treats a small difference as "already there".
        XCTAssertFalse(AmbientBrightnessSync.shouldWrite(current: 0.5, target: 0.55, epsilon: 0.1))
        XCTAssertTrue(AmbientBrightnessSync.shouldWrite(current: 0.5, target: 0.55, epsilon: 0.01))
    }
}
