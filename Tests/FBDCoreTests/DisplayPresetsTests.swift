import CoreGraphics
import XCTest
@testable import FBDCore

/// Named display presets: the store's persistence contract, name resolution,
/// icon fail-closed behaviour, and the outcome the applier reports.
///
/// The apply itself drives hardware (ResolutionController/DisplayController),
/// which unit tests cannot observe; what *is* testable — and what these pin — is
/// the storage shape, the naming rules that keep `apply <name>` unambiguous, and
/// the narrowing the applier does before it touches a display.
@MainActor
final class DisplayPresetsTests: XCTestCase {
    private let suiteName = "test.fbd.displaypresets"

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    private func makeDisplay(
        id: CGDirectDisplayID = 1,
        vendor: UInt32 = 0x10AC,
        model: UInt32 = 0x1234
    ) -> Display {
        Display(
            id: id,
            name: "Preset Test",
            isBuiltin: false,
            vendorNumber: vendor,
            modelNumber: model,
            serialNumber: 0x5678,
            bounds: .zero,
            isOnline: true,
            isActive: true
        )
    }

    private func preset(
        name: String = "Desk",
        symbol: DisplayPresetSymbol = .display,
        properties: ProtectedProperties = DisplayPresets.defaultProperties,
        state: DisplayStateSnapshot = DisplayStateSnapshot(brightness: 0.5)
    ) -> DisplayPreset {
        DisplayPreset(name: name, symbol: symbol, properties: properties, state: state)
    }

    // MARK: - Storage

    func testSaveWritesToInjectedDomainUnderIdentityKey() {
        let display = makeDisplay()
        XCTAssertTrue(DisplayPresets.save(preset(), for: display.identityKey, defaults: defaults))

        let key = "displayPresets.\(display.identityKey)"
        XCTAssertNotNil(defaults.data(forKey: key), "presets must land under the identity key in the injected suite")
        XCTAssertNil(UserDefaults.standard.data(forKey: key), "must not write to UserDefaults.standard")
    }

    func testPresetsRoundTripInSaveOrder() {
        let identity = makeDisplay().identityKey
        let a = preset(name: "Alpha")
        let b = preset(name: "Beta")
        let c = preset(name: "Gamma")

        XCTAssertTrue(DisplayPresets.save(a, for: identity, defaults: defaults))
        XCTAssertTrue(DisplayPresets.save(b, for: identity, defaults: defaults))
        XCTAssertTrue(DisplayPresets.save(c, for: identity, defaults: defaults))

        XCTAssertEqual(DisplayPresets.presets(for: identity, defaults: defaults), [a, b, c])
    }

    func testSaveByIdReplacesInPlace() {
        let identity = makeDisplay().identityKey
        let a = preset(name: "Alpha")
        var b = preset(name: "Beta")
        let c = preset(name: "Gamma")
        for item in [a, b, c] { DisplayPresets.save(item, for: identity, defaults: defaults) }

        b.name = "Beta renamed"
        XCTAssertTrue(DisplayPresets.save(b, for: identity, defaults: defaults))

        let stored = DisplayPresets.presets(for: identity, defaults: defaults)
        XCTAssertEqual(stored.map(\.name), ["Alpha", "Beta renamed", "Gamma"], "a rename must not reorder the list")
        XCTAssertEqual(stored.map(\.id), [a.id, b.id, c.id])
    }

    func testPresetsAreIsolatedPerDisplayIdentity() {
        let displayA = makeDisplay(model: 0x1111)
        let displayB = makeDisplay(model: 0x2222)

        DisplayPresets.save(preset(name: "Only A"), for: displayA.identityKey, defaults: defaults)

        XCTAssertEqual(DisplayPresets.presets(for: displayA.identityKey, defaults: defaults).count, 1)
        XCTAssertTrue(DisplayPresets.presets(for: displayB.identityKey, defaults: defaults).isEmpty)
    }

    func testRemoveDropsTheKeyWhenTheLastPresetGoes() {
        let identity = makeDisplay().identityKey
        let only = preset()
        DisplayPresets.save(only, for: identity, defaults: defaults)

        XCTAssertTrue(DisplayPresets.remove(id: only.id, for: identity, defaults: defaults))
        XCTAssertTrue(DisplayPresets.presets(for: identity, defaults: defaults).isEmpty)
        XCTAssertNil(
            defaults.object(forKey: "displayPresets.\(identity)"),
            "an identity whose last preset was removed must leave no residue behind"
        )
        XCTAssertFalse(DisplayPresets.remove(id: only.id, for: identity, defaults: defaults), "removing twice reports false")
    }

    func testCorruptDataReadsAsEmptyWithoutCrashing() {
        let identity = makeDisplay().identityKey
        defaults.set(Data("not-json".utf8), forKey: "displayPresets.\(identity)")

        XCTAssertTrue(DisplayPresets.presets(for: identity, defaults: defaults).isEmpty)
        // And the store still works after seeing rubbish.
        XCTAssertTrue(DisplayPresets.save(preset(), for: identity, defaults: defaults))
        XCTAssertEqual(DisplayPresets.presets(for: identity, defaults: defaults).count, 1)
    }

    // MARK: - Names

    func testDuplicateNameIsRefusedSoApplyByNameStaysUnambiguous() {
        let identity = makeDisplay().identityKey
        XCTAssertTrue(DisplayPresets.save(preset(name: "Work"), for: identity, defaults: defaults))
        XCTAssertFalse(
            DisplayPresets.save(preset(name: "Work"), for: identity, defaults: defaults),
            "a second preset with the same name would make `apply <name>` ambiguous"
        )
        XCTAssertEqual(DisplayPresets.presets(for: identity, defaults: defaults).count, 1)
    }

    func testDuplicateNameIsRefusedCaseInsensitivelyAndAfterTrimming() {
        let identity = makeDisplay().identityKey
        DisplayPresets.save(preset(name: "Work"), for: identity, defaults: defaults)
        XCTAssertFalse(DisplayPresets.save(preset(name: "  work  "), for: identity, defaults: defaults))
    }

    func testAPresetMayKeepItsOwnNameWhenResaved() {
        let identity = makeDisplay().identityKey
        var item = preset(name: "Work")
        DisplayPresets.save(item, for: identity, defaults: defaults)

        item.state = DisplayStateSnapshot(brightness: 0.9)
        XCTAssertTrue(
            DisplayPresets.save(item, for: identity, defaults: defaults),
            "re-saving a preset under its own name is not a collision"
        )
        XCTAssertEqual(DisplayPresets.presets(for: identity, defaults: defaults).first?.state.brightness, 0.9)
    }

    func testUnusableNamesAreRefused() {
        let identity = makeDisplay().identityKey
        for bad in ["", "   ", "\n\t"] {
            XCTAssertFalse(DisplayPresets.save(preset(name: bad), for: identity, defaults: defaults))
        }
        XCTAssertTrue(DisplayPresets.presets(for: identity, defaults: defaults).isEmpty)
    }

    func testSavedNameIsTrimmedAndCapped() {
        let identity = makeDisplay().identityKey
        let long = String(repeating: "x", count: 200)
        XCTAssertTrue(DisplayPresets.save(preset(name: "  Padded  "), for: identity, defaults: defaults))
        XCTAssertTrue(DisplayPresets.save(preset(name: long), for: identity, defaults: defaults))

        let names = DisplayPresets.presets(for: identity, defaults: defaults).map(\.name)
        XCTAssertEqual(names.first, "Padded")
        XCTAssertEqual(names.last?.count, DisplayPreset.maximumNameLength)
    }

    func testLookupByNameIsCaseInsensitive() {
        let identity = makeDisplay().identityKey
        let item = preset(name: "Desk")
        DisplayPresets.save(item, for: identity, defaults: defaults)

        XCTAssertEqual(DisplayPresets.preset(named: "desk", for: identity, defaults: defaults)?.id, item.id)
        XCTAssertEqual(DisplayPresets.preset(named: " DESK ", for: identity, defaults: defaults)?.id, item.id)
        XCTAssertNil(DisplayPresets.preset(named: "nope", for: identity, defaults: defaults))
    }

    func testResolveAcceptsANameOrAUUID() {
        let identity = makeDisplay().identityKey
        let item = preset(name: "Desk")
        DisplayPresets.save(item, for: identity, defaults: defaults)

        XCTAssertEqual(DisplayPresets.resolve("Desk", for: identity, defaults: defaults)?.id, item.id)
        XCTAssertEqual(DisplayPresets.resolve(item.id.uuidString, for: identity, defaults: defaults)?.id, item.id)
        XCTAssertNil(DisplayPresets.resolve("11111111-1111-1111-1111-111111111111", for: identity, defaults: defaults))
        XCTAssertNil(DisplayPresets.resolve("", for: identity, defaults: defaults))
    }

    // MARK: - Default selection

    func testDefaultPropertiesAreEverythingButMainStatus() {
        XCTAssertEqual(DisplayPresets.defaultProperties, ProtectedProperties.all.subtracting(.mainStatus))
        XCTAssertFalse(
            DisplayPresets.defaultProperties.contains(.mainStatus),
            "applying a preset must not silently move the menu bar to another display"
        )
        XCTAssertTrue(DisplayPresets.defaultProperties.contains(.brightness))
        XCTAssertTrue(DisplayPresets.defaultProperties.contains(.colourProfile))
    }

    // MARK: - Codable

    func testFullSnapshotRoundTrips() throws {
        let state = DisplayStateSnapshot(
            modeNumber: 7,
            refreshRate: 59.94,
            brightness: 0.42,
            activePresetIndex: 3,
            isHDRModeEnabled: true,
            isMain: true,
            rotationDegrees: 270,
            colourProfilePath: "/Library/x.icc"
        )
        let item = preset(name: "Full", symbol: .game, properties: [.resolution, .brightness], state: state)

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(DisplayPreset.self, from: data)
        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.symbol, .game)
    }

    func testASparseSnapshotDecodes() throws {
        let json = #"""
        {"id":"11111111-1111-1111-1111-111111111111","name":"A","symbol":"display",
         "properties":8,"state":{"modeNumber":5}}
        """#
        let decoded = try JSONDecoder().decode(DisplayPreset.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.state.modeNumber, 5)
        XCTAssertNil(decoded.state.brightness)
        XCTAssertNil(decoded.state.colourProfilePath)
        XCTAssertEqual(decoded.properties, .preset)
    }

    func testAnUnknownSymbolNameDecodesToTheDefault() throws {
        let json = #"""
        {"id":"11111111-1111-1111-1111-111111111111","name":"A","symbol":"symbol.from.the.future",
         "properties":1,"state":{}}
        """#
        let decoded = try JSONDecoder().decode(DisplayPreset.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.symbol, .default, "one unrecognised symbol must not make the preset unreadable")
    }

    // MARK: - Symbols

    func testUnknownSymbolResolvesToTheDefault() {
        XCTAssertEqual(DisplayPresetSymbol.resolve("not.a.symbol"), .default)
        XCTAssertEqual(DisplayPresetSymbol.resolve(nil), .default)
        XCTAssertEqual(DisplayPresetSymbol.resolve("gamecontroller"), .game)
    }

    func testSymbolNamesAreUniqueAndEncodeAsTheSFName() throws {
        let names = DisplayPresetSymbol.all.map(\.symbolName)
        XCTAssertEqual(Set(names).count, names.count, "two symbols sharing an SF name would be indistinguishable")

        XCTAssertEqual(try String(data: JSONEncoder().encode(DisplayPresetSymbol.game), encoding: .utf8), "\"gamecontroller\"")
    }

    /// The strict lookup behind `fbdcli config preset … --symbol`. It has to accept every
    /// spelling a person is likely to type — the SF name, the case name, the picker label — and
    /// refuse everything else rather than quietly handing back the default icon.
    func testTypedSymbolNamesAcceptEverySpellingAndRefuseTheRest() {
        XCTAssertEqual(DisplayPresetSymbol.named("tv"), .screen)
        XCTAssertEqual(DisplayPresetSymbol.named("screen"), .screen)
        XCTAssertEqual(DisplayPresetSymbol.named("TV"), .screen)
        XCTAssertEqual(DisplayPresetSymbol.named(" laptopcomputer "), .laptop)
        XCTAssertEqual(DisplayPresetSymbol.named("Laptop"), .laptop)
        XCTAssertEqual(DisplayPresetSymbol.named("gamecontroller"), .game)
        XCTAssertEqual(DisplayPresetSymbol.named("Game"), .game)

        XCTAssertNil(DisplayPresetSymbol.named("screen.2"))
        XCTAssertNil(DisplayPresetSymbol.named(""))
        XCTAssertNil(DisplayPresetSymbol.named("   "))

        // Every offered symbol answers to its own three spellings.
        for symbol in DisplayPresetSymbol.all {
            XCTAssertEqual(DisplayPresetSymbol.named(symbol.symbolName), symbol)
            XCTAssertEqual(DisplayPresetSymbol.named(symbol.label), symbol)
            XCTAssertEqual(DisplayPresetSymbol.named(String(describing: symbol)), symbol)
        }
    }

    // MARK: - Applying

    func testApplierReportsWhatTheDisplayNoLongerExposes() {
        let display = makeDisplay()
        // A display that reports a mode but no brightness/XDR/HDR path.
        let mode = DisplayMode(
            modeNumber: 3,
            flags: DisplayMode.safeFlag,
            width: 1920,
            height: 1080,
            pixelsWide: 1920,
            pixelsHigh: 1080,
            refreshRate: 60,
            encoding: "RGB "
        )
        display.updateModes([mode], current: mode)

        let outcome = DisplayPresetApplier.apply(
            preset(properties: .all),
            to: display,
            resolution: ResolutionController(),
            controller: DisplayController()
        )

        XCTAssertEqual(outcome.requested, .all)
        XCTAssertEqual(outcome.unavailable, [.brightness, .preset, .hdrMode])
        XCTAssertEqual(outcome.applied, [.resolution, .refreshRate, .mainStatus, .rotation, .colourProfile])
    }

    func testApplierNarrowsToTheDisplaysCapabilitiesOnly() {
        let display = makeDisplay() // bare: only main status is available
        let outcome = DisplayPresetApplier.apply(
            preset(properties: [.resolution, .brightness]),
            to: display,
            resolution: ResolutionController(),
            controller: DisplayController()
        )

        XCTAssertEqual(outcome.requested, [.resolution, .brightness])
        XCTAssertEqual(outcome.unavailable, [.resolution, .brightness])
        XCTAssertEqual(outcome.applied, [])
    }
}
