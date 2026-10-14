import XCTest
@testable import FBDCore

/// The HUD's style (gap-matrix row #29).
///
/// Every field is persisted JSON, so the tests are mostly about what a *stored*
/// value may do: the defaults have to reproduce the look FBD shipped before this
/// was configurable, and nothing out of range may reach the renderer.
final class OSDStyleTests: XCTestCase {
    private let suiteName = "test.fbd.osdstyle"
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

    // MARK: - Defaults

    /// The defaults must be exactly what FBD already did — top centre, 8pt under the
    /// menu bar, a continuous bar, the dark HUD, a shadow and a 12pt radius — or an
    /// existing install would change appearance without being asked.
    func testDefaultsAreTheIncumbentLook() {
        let style = OSDStyle.standard
        XCTAssertEqual(style.position, .topCenter)
        XCTAssertEqual(style.barStyle, .continuous)
        XCTAssertEqual(style.background, .hudDark)
        XCTAssertTrue(style.showsShadow)
        XCTAssertEqual(style.cornerRadius, 12)
        XCTAssertEqual(style.segmentCount, 16)
    }

    func testEveryCaseHasALabel() {
        for position in OSDStyle.Position.allCases { XCTAssertFalse(position.label.isEmpty) }
        for bar in OSDStyle.BarStyle.allCases { XCTAssertFalse(bar.label.isEmpty) }
        for background in OSDStyle.Background.allCases { XCTAssertFalse(background.label.isEmpty) }
    }

    // MARK: - Clamping

    func testClampBringsValuesInsideTheirRanges() {
        XCTAssertEqual(OSDStyle(cornerRadius: 999).clamped().cornerRadius, 28)
        XCTAssertEqual(OSDStyle(cornerRadius: -5).clamped().cornerRadius, 0)
        XCTAssertEqual(OSDStyle(segmentCount: 500).clamped().segmentCount, 32)
        XCTAssertEqual(OSDStyle(segmentCount: 1).clamped().segmentCount, 4)
        XCTAssertEqual(OSDStyle(cornerRadius: 18).clamped().cornerRadius, 18, "a value in range is untouched")
    }

    /// A non-finite radius falls back to the default rather than to an extreme: a
    /// HUD the user cannot read is worse than one at the shipped size. Same rule as
    /// `BrightnessPreferences`.
    func testClampFallsBackForNonFiniteValues() {
        XCTAssertEqual(OSDStyle(cornerRadius: .nan).clamped().cornerRadius, OSDStyle.defaultCornerRadius)
        XCTAssertEqual(OSDStyle(cornerRadius: .infinity).clamped().cornerRadius, OSDStyle.defaultCornerRadius)
    }

    func testClampIsIdempotent() {
        let once = OSDStyle(cornerRadius: 900, segmentCount: -3).clamped()
        XCTAssertEqual(once.clamped(), once)
    }

    // MARK: - Persistence

    func testRoundTripThroughTheInjectedSuite() {
        var style = OSDStyle.standard
        style.position = .bottomCenter
        style.barStyle = .segmented
        style.background = .adaptive
        style.showsShadow = false
        style.cornerRadius = 20
        style.segmentCount = 24
        OSDStyle.save(style, defaults: defaults)

        XCTAssertEqual(OSDStyle.load(defaults: defaults), style)
        XCTAssertNotNil(defaults.data(forKey: Settings.osdStyleKey))
        XCTAssertNil(
            UserDefaults.standard.data(forKey: Settings.osdStyleKey),
            "must not write to UserDefaults.standard"
        )
    }

    /// Nothing stored yet, and a corrupt blob, both land on the shipped look.
    func testUnreadableDataFallsBackToTheDefaults() {
        XCTAssertEqual(OSDStyle.load(defaults: defaults), .standard)

        defaults.set(Data("not-json".utf8), forKey: Settings.osdStyleKey)
        XCTAssertEqual(OSDStyle.load(defaults: defaults), .standard)
    }

    /// What is stored is clamped, so a hand-edited out-of-range value cannot reach
    /// the renderer even before a read clamps it again.
    func testSavingClampsWhatIsStored() {
        OSDStyle.save(OSDStyle(cornerRadius: 4000, segmentCount: 900), defaults: defaults)
        let reloaded = OSDStyle.load(defaults: defaults)
        XCTAssertEqual(reloaded.cornerRadius, 28)
        XCTAssertEqual(reloaded.segmentCount, 32)
    }
}
