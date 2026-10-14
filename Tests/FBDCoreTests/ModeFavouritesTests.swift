import XCTest
@testable import FBDCore

/// Resolution-favourites persistence + recall. Pure: every test runs against a
/// scratch UserDefaults suite, so no real display and no shared domain are
/// touched.
final class ModeFavouritesTests: XCTestCase {
    private let suiteName = "test.fbd.modefavourites"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeMode(
        modeNumber: Int32 = 7,
        width: Int32 = 1920,
        height: Int32 = 1080,
        pixelsWide: Int32 = 3840,
        pixelsHigh: Int32 = 2160,
        refreshRate: Double = 60,
        hiDPI: Bool = true
    ) -> DisplayMode {
        DisplayMode(
            modeNumber: modeNumber,
            flags: (hiDPI ? DisplayMode.hiDPIFlag : 0) | DisplayMode.safeFlag,
            width: width,
            height: height,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            refreshRate: refreshRate,
            encoding: "RGB "
        )
    }

    // MARK: - Save / read / clear round-trip

    func testSaveThenReadRoundTripsThroughScratchSuite() {
        let mode = makeMode(modeNumber: 11, refreshRate: 59.94)

        XCTAssertTrue(ModeFavourites.save(mode, into: 3, for: "display-a", defaults: defaults))

        let read = ModeFavourites.favourite(slot: 3, for: "display-a", defaults: defaults)
        XCTAssertEqual(read, Optional(ModeFavourite(slot: 3, mode: mode)))
    }

    func testReadOfAnEmptySlotIsNil() {
        XCTAssertNil(ModeFavourites.favourite(slot: 1, for: "display-a", defaults: defaults))
    }

    func testClearRemovesTheSlot() {
        XCTAssertTrue(ModeFavourites.save(makeMode(), into: 2, for: "display-a", defaults: defaults))

        XCTAssertTrue(ModeFavourites.clear(slot: 2, for: "display-a", defaults: defaults))
        XCTAssertNil(ModeFavourites.favourite(slot: 2, for: "display-a", defaults: defaults))
    }

    func testClearingTheLastSlotLeavesNoResidueKey() {
        XCTAssertTrue(ModeFavourites.save(makeMode(), into: 5, for: "display-a", defaults: defaults))
        let key = ModeFavourites.defaultsKey(for: "display-a")
        XCTAssertNotNil(defaults.data(forKey: key))

        XCTAssertTrue(ModeFavourites.clear(slot: 5, for: "display-a", defaults: defaults))
        XCTAssertNil(defaults.data(forKey: key), "the key must be removed, not left as an empty array")
    }

    func testClearIsIdempotentOnAnAlreadyEmptySlot() {
        XCTAssertTrue(ModeFavourites.clear(slot: 4, for: "display-a", defaults: defaults))
    }

    func testSaveOverwritesTheSameSlot() {
        XCTAssertTrue(ModeFavourites.save(makeMode(modeNumber: 1), into: 1, for: "d", defaults: defaults))
        XCTAssertTrue(ModeFavourites.save(makeMode(modeNumber: 2), into: 1, for: "d", defaults: defaults))

        XCTAssertEqual(ModeFavourites.favourite(slot: 1, for: "d", defaults: defaults)?.modeNumber, 2)
        XCTAssertEqual(ModeFavourites.favourites(for: "d", defaults: defaults).count, 1)
    }

    // MARK: - Slot bounds are refused, never trapped

    func testSaveRefusesSlotAboveRange() {
        XCTAssertFalse(ModeFavourites.save(makeMode(), into: 6, for: "d", defaults: defaults))
        XCTAssertNil(ModeFavourites.favourite(slot: 6, for: "d", defaults: defaults))
    }

    func testSaveRefusesSlotBelowRange() {
        XCTAssertFalse(ModeFavourites.save(makeMode(), into: 0, for: "d", defaults: defaults))
    }

    func testSaveRefusesNegativeSlot() {
        XCTAssertFalse(ModeFavourites.save(makeMode(), into: -1, for: "d", defaults: defaults))
    }

    func testFavouriteRefusesOutOfRangeSlot() {
        XCTAssertNil(ModeFavourites.favourite(slot: 99, for: "d", defaults: defaults))
    }

    func testClearRefusesOutOfRangeSlot() {
        XCTAssertFalse(ModeFavourites.clear(slot: 6, for: "d", defaults: defaults))
    }

    func testSlotCountAndRange() {
        XCTAssertEqual(ModeFavourites.slotCount, 5)
        XCTAssertEqual(ModeFavourites.validSlots, 1...5)
    }

    // MARK: - Listing

    func testFavouritesListsNonEmptySlotsInOrder() {
        XCTAssertTrue(ModeFavourites.save(makeMode(modeNumber: 3), into: 4, for: "d", defaults: defaults))
        XCTAssertTrue(ModeFavourites.save(makeMode(modeNumber: 1), into: 1, for: "d", defaults: defaults))
        XCTAssertTrue(ModeFavourites.save(makeMode(modeNumber: 2), into: 3, for: "d", defaults: defaults))

        XCTAssertEqual(ModeFavourites.favourites(for: "d", defaults: defaults).map { $0.slot }, [1, 3, 4])
    }

    func testFavouritesIsEmptyForAnUnknownIdentity() {
        XCTAssertTrue(ModeFavourites.favourites(for: "nobody", defaults: defaults).isEmpty)
    }

    // MARK: - Per-identity isolation

    func testFavouritesAreIsolatedPerIdentity() {
        XCTAssertTrue(ModeFavourites.save(makeMode(modeNumber: 10), into: 1, for: "display-a", defaults: defaults))
        XCTAssertTrue(ModeFavourites.save(makeMode(modeNumber: 20), into: 1, for: "display-b", defaults: defaults))

        XCTAssertEqual(ModeFavourites.favourite(slot: 1, for: "display-a", defaults: defaults)?.modeNumber, 10)
        XCTAssertEqual(ModeFavourites.favourite(slot: 1, for: "display-b", defaults: defaults)?.modeNumber, 20)
    }

    func testClearingOneIdentityLeavesAnotherIntact() {
        XCTAssertTrue(ModeFavourites.save(makeMode(modeNumber: 10), into: 2, for: "display-a", defaults: defaults))
        XCTAssertTrue(ModeFavourites.save(makeMode(modeNumber: 20), into: 2, for: "display-b", defaults: defaults))

        XCTAssertTrue(ModeFavourites.clear(slot: 2, for: "display-a", defaults: defaults))
        XCTAssertNil(ModeFavourites.favourite(slot: 2, for: "display-a", defaults: defaults))
        XCTAssertEqual(ModeFavourites.favourite(slot: 2, for: "display-b", defaults: defaults)?.modeNumber, 20)
    }

    // MARK: - JSON persistence + key shape

    func testStoredBlobIsJSONUnderTheIdentityKey() throws {
        XCTAssertTrue(ModeFavourites.save(makeMode(modeNumber: 42), into: 1, for: "display-a", defaults: defaults))

        let data = try XCTUnwrap(defaults.data(forKey: "modeFavourites.display-a"))
        let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(list?.count, 1)
        XCTAssertEqual(list?.first?["modeNumber"] as? Int, 42)
        XCTAssertEqual(list?.first?["slot"] as? Int, 1)
    }

    func testPersistedFavouriteSurvivesAFreshRead() throws {
        // One call saves; a separate call reads it back purely from the suite,
        // proving the value is persisted rather than cached.
        XCTAssertTrue(ModeFavourites.save(makeMode(modeNumber: 8, refreshRate: 120), into: 2, for: "x", defaults: defaults))

        let reloaded = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)?.data(forKey: "modeFavourites.x")
        )
        let list = try XCTUnwrap(JSONDecoder().decode([ModeFavourite].self, from: reloaded))
        XCTAssertEqual(list.first?.modeNumber, 8)
        XCTAssertEqual(list.first?.refreshRate, 120)
    }

    // MARK: - Recall: exact vs equivalent vs unavailable

    func testRecallExactWhenModeNumberStillExists() {
        let recorded = makeMode(modeNumber: 100, pixelsWide: 3840, pixelsHigh: 2160, refreshRate: 60)
        XCTAssertTrue(ModeFavourites.save(recorded, into: 1, for: "d", defaults: defaults))

        // Current list still offers mode 100, but at a different refresh rate —
        // the exact mode number must win.
        let current = makeMode(modeNumber: 100, pixelsWide: 3840, pixelsHigh: 2160, refreshRate: 120)
        let recall = ModeFavourites.recall(slot: 1, for: "d", against: [current], defaults: defaults)

        XCTAssertEqual(recall, .exact(current))
    }

    func testRecallEquivalentWhenModeNumberIsGoneButShapeMatches() {
        let recorded = makeMode(modeNumber: 100, pixelsWide: 3840, pixelsHigh: 2160, refreshRate: 60)
        XCTAssertTrue(ModeFavourites.save(recorded, into: 1, for: "d", defaults: defaults))

        // Mode 100 is gone; a different number with the same pixels + rate is
        // the equivalent fallback.
        let equivalent = makeMode(modeNumber: 250, pixelsWide: 3840, pixelsHigh: 2160, refreshRate: 60)
        let recall = ModeFavourites.recall(slot: 1, for: "d", against: [equivalent], defaults: defaults)

        XCTAssertEqual(recall, .equivalent(equivalent))
    }

    func testRecallUnavailableWhenModeNumberGoneAndRefreshRateDiffers() {
        let recorded = makeMode(modeNumber: 100, pixelsWide: 3840, pixelsHigh: 2160, refreshRate: 60)
        XCTAssertTrue(ModeFavourites.save(recorded, into: 1, for: "d", defaults: defaults))

        // Same pixels, different rate: not equivalent, and no exact match.
        let other = makeMode(modeNumber: 250, pixelsWide: 3840, pixelsHigh: 2160, refreshRate: 59.94)
        XCTAssertEqual(
            ModeFavourites.recall(slot: 1, for: "d", against: [other], defaults: defaults),
            .unavailable
        )
    }

    func testRecallUnavailableWhenModeNumberGoneAndPixelsDiffer() {
        let recorded = makeMode(modeNumber: 100, pixelsWide: 3840, pixelsHigh: 2160, refreshRate: 60)
        XCTAssertTrue(ModeFavourites.save(recorded, into: 1, for: "d", defaults: defaults))

        let other = makeMode(modeNumber: 250, pixelsWide: 2560, pixelsHigh: 1440, refreshRate: 60)
        XCTAssertEqual(
            ModeFavourites.recall(slot: 1, for: "d", against: [other], defaults: defaults),
            .unavailable
        )
    }

    func testRecallFromEmptySlotIsUnavailable() {
        XCTAssertEqual(
            ModeFavourites.recall(slot: 3, for: "d", against: [makeMode()], defaults: defaults),
            .unavailable
        )
    }

    func testRecallFromOutOfRangeSlotIsUnavailable() {
        XCTAssertEqual(
            ModeFavourites.recall(slot: 0, for: "d", against: [makeMode()], defaults: defaults),
            .unavailable
        )
    }

    func testResolveIsPureAndSkipsUnavailableWithoutAMatch() {
        let favourite = ModeFavourite(slot: 1, mode: makeMode(modeNumber: 1))
        XCTAssertEqual(ModeFavourites.resolve(favourite, against: []), .unavailable)
    }

    func testRecallUnavailableExposesNilModeAndFlag() {
        let recall = ModeRecall.unavailable
        XCTAssertNil(recall.displayMode)
        XCTAssertTrue(recall.isUnavailable)
    }

    func testEquivalentRecallExposesTheMatchedMode() {
        let mode = makeMode(modeNumber: 9)
        XCTAssertEqual(ModeRecall.equivalent(mode).displayMode, Optional(mode))
        XCTAssertFalse(ModeRecall.equivalent(mode).isUnavailable)
    }

    // MARK: - Settings accessor thin front

    func testSettingsAccessorsRoundTripInSharedSuiteButStillRefuseBadSlots() {
        // These go through Settings.defaults (the shared suite) by design; use a
        // value that is harmless if it lingers, and clean it up.
        let identity = "test.fbd.settings-accessor"
        let mode = makeMode(modeNumber: 3)
        defer {
            Settings.clearModeFavourite(slot: 2, for: identity)
        }

        XCTAssertTrue(Settings.setModeFavourite(mode, slot: 2, for: identity))
        XCTAssertEqual(Settings.modeFavourite(slot: 2, for: identity)?.modeNumber, 3)
        XCTAssertEqual(Settings.modeFavourites(for: identity).map { $0.slot }, [2])
        XCTAssertFalse(Settings.setModeFavourite(mode, slot: 0, for: identity))
    }
}
