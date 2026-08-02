import XCTest
@testable import FBDCore

final class SettingsTests: XCTestCase {
    /// Dedicated suite so Storage tests never touch UserDefaults.standard.
    private let suiteName = "test.fbd.settings"
    /// Unique identity so ddcFeatures tests (which use UserDefaults.standard)
    /// cannot collide with real per-display keys.
    private var ddcIdentity = ""

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        ddcIdentity = "test.fbd.settings.\(UUID().uuidString)"
    }

    override func tearDown() {
        Settings.clearDDCFeatures(for: ddcIdentity)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Storage wrapper

    func testStorageIntDefaultsToProvidedValueBeforeWrite() {
        // Arrange
        @Storage(key: "intKey", defaultValue: 42, suite: suiteName) var stored: Int

        // Act
        let initial = stored
        stored = 100

        // Assert
        XCTAssertEqual(initial, 42)
        XCTAssertEqual(stored, 100)
    }

    func testStorageIntWritesToSuiteNotStandardDefaults() {
        // Arrange
        @Storage(key: "intKey", defaultValue: 42, suite: suiteName) var stored: Int

        // Act
        stored = 100

        // Assert
        XCTAssertEqual(UserDefaults(suiteName: suiteName)?.integer(forKey: "intKey"), 100)
        XCTAssertNil(UserDefaults.standard.object(forKey: "intKey"))
    }

    func testStoragePersistsAcrossInstancesInSameSuite() {
        // Arrange
        @Storage(key: "intKey", defaultValue: 42, suite: suiteName) var first: Int

        // Act
        first = 7

        // Assert
        @Storage(key: "intKey", defaultValue: 42, suite: suiteName) var second: Int
        XCTAssertEqual(second, 7)
    }

    func testStorageBoolRoundtrip() {
        // Arrange
        @Storage(key: "boolKey", defaultValue: true, suite: suiteName) var stored: Bool

        // Act
        stored = false

        // Assert
        XCTAssertFalse(stored)
        XCTAssertEqual(UserDefaults(suiteName: suiteName)?.bool(forKey: "boolKey"), false)
    }

    // MARK: - DDC features persistence

    func testDDCFeaturesEmptyByDefault() {
        // Act
        let features = Settings.ddcFeatures(for: ddcIdentity)

        // Assert
        XCTAssertTrue(features.isEmpty)
    }

    func testDDCFeaturesRoundtrip() {
        // Arrange
        let expected: Set<UInt8> = [0x10, 0x62, 0x8D]

        // Act
        Settings.setDDCFeatures(expected, for: ddcIdentity)
        let loaded = Settings.ddcFeatures(for: ddcIdentity)

        // Assert
        XCTAssertEqual(loaded, expected)
    }

    func testClearDDCFeaturesRemovesPersistedFeatures() {
        // Arrange
        Settings.setDDCFeatures([0x10, 0x62], for: ddcIdentity)

        // Act
        Settings.clearDDCFeatures(for: ddcIdentity)

        // Assert
        XCTAssertTrue(Settings.ddcFeatures(for: ddcIdentity).isEmpty)
    }


    // MARK: - Persisted model round-trips

    func testVirtualScreenConfigsRoundtrip() {
        let configs = [
            VirtualScreenConfig(
                id: "A", name: "Alpha", width: 1920, height: 1080,
                refreshRate: 60, isHDR: true, autoConnect: true
            ),
            VirtualScreenConfig(
                id: "B", name: "Beta", width: 1280, height: 720,
                refreshRate: 120, isHDR: false, autoConnect: false
            ),
        ]
        defer { Settings.saveVirtualScreens([]) }

        Settings.saveVirtualScreens(configs)
        XCTAssertEqual(Settings.loadVirtualScreens(), configs)

        Settings.saveVirtualScreens([])
        XCTAssertTrue(Settings.loadVirtualScreens().isEmpty)
    }

    func testLayoutAnchorsRoundtrip() {
        let anchors = [
            LayoutAnchor(displayID: 1, x: 0, y: 0),
            LayoutAnchor(displayID: 2, x: 1920, y: 0),
        ]
        defer { Settings.saveLayoutAnchors([]) }

        Settings.saveLayoutAnchors(anchors)
        XCTAssertEqual(Settings.loadLayoutAnchors(), anchors)

        Settings.saveLayoutAnchors([])
        XCTAssertTrue(Settings.loadLayoutAnchors().isEmpty)
    }

    func testVirtualScreenConfigCodableFormatStability() {
        // Locks the on-disk JSON format: saved data must decode across app
        // versions, so adding/renaming fields is a deliberate change.
        let config = VirtualScreenConfig(
            id: "FIXED-ID", name: "Format Lock", width: 1920, height: 1080,
            refreshRate: 60, isHDR: true, autoConnect: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(config)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertEqual(
            json,
            #"{"autoConnect":true,"height":1080,"id":"FIXED-ID","isHDR":true,"name":"Format Lock","refreshRate":60,"width":1920}"#
        )

        // Hand-written JSON (e.g. saved by an older build) must decode.
        let legacy = #"{"autoConnect":true,"height":1080,"id":"FIXED-ID","isHDR":true,"name":"Format Lock","refreshRate":60,"width":1920}"#
        XCTAssertEqual(try? JSONDecoder().decode(VirtualScreenConfig.self, from: Data(legacy.utf8)), config)
    }

    // MARK: - Debug summary

    func testDebugSummaryMasksSecrets() {
        let token = Settings.httpAPIToken
        let summary = Settings.debugSummary

        XCTAssertTrue(summary.contains("ddcCooldownMilliseconds ="), "expected settings keys in the dump")
        XCTAssertTrue(summary.contains("httpAPIToken = "), "token key must be present")
        XCTAssertFalse(summary.contains(token), "full token must never appear")
        // The LG pairing key must be masked; guard the empty case (an empty
        // value is a prefix of the masked entry, so only check non-empty).
        if !Settings.tvLGClientKey.isEmpty {
            XCTAssertFalse(summary.contains("tvLGClientKey = \(Settings.tvLGClientKey)"), "LG key must be masked")
        }
        XCTAssertTrue(summary.contains("tvLGClientKey = "), "LG key entry must be present")
        XCTAssertTrue(summary.contains("ddcReadRetries = \(Settings.ddcReadRetries)"))
    }

    func testDebugSummaryIsSorted() {
        let lines = Settings.debugSummary.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, lines.sorted())
    }
}

    func testLayoutAnchorCodableFormatStability() {
        // Locks the on-disk JSON format for saved arrangements (upgrade-safe
        // decode across app versions).
        let anchor = LayoutAnchor(displayID: 42, x: 1920, y: -100)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try! encoder.encode(anchor), encoding: .utf8)!

        XCTAssertEqual(json, #"{"displayID":42,"x":1920,"y":-100}"#)

        let legacy = #"{"displayID":42,"x":1920,"y":-100}"#
        XCTAssertEqual(try? JSONDecoder().decode(LayoutAnchor.self, from: Data(legacy.utf8)), anchor)
    }
