import XCTest
@testable import FBDCore

/// Row #13: the status item's icon choice and its visibility rule. Both are
/// pure, which is the point — the item itself cannot be asserted on without a
/// running app, but the decisions behind it can.
final class MenuBarIconTests: XCTestCase {
    // MARK: - Icon choice

    func testEveryCaseRoundTripsThroughItsRawValue() {
        for style in MenuBarIconStyle.allCases {
            XCTAssertEqual(MenuBarIconStyle(rawValue: style.rawValue), style)
        }
    }

    func testUnknownStoredValueDegradesToTheDefault() {
        // The stored value is a raw string, so an unrecognised one must not trap
        // and must not leave the button imageless.
        XCTAssertNil(MenuBarIconStyle(rawValue: "not.a.real.symbol"))
        XCTAssertEqual(MenuBarIconStyle(rawValue: "not.a.real.symbol") ?? .default, .display)
    }

    func testSymbolNamesAreNonEmptyAndUnique() {
        let names = MenuBarIconStyle.allCases.map { $0.symbolName }
        XCTAssertFalse(names.contains { $0.isEmpty })
        XCTAssertEqual(Set(names).count, names.count, "two cases share a symbol name")
    }

    func testLabelsAreNonEmptyAndUnique() {
        let labels = MenuBarIconStyle.allCases.map { $0.label }
        XCTAssertFalse(labels.contains { $0.isEmpty })
        XCTAssertEqual(Set(labels).count, labels.count, "two cases share a picker label")
    }

    func testTheDefaultIsOfferedInThePickersCaseList() {
        // A default that the picker cannot select would be unshowable in the UI.
        XCTAssertTrue(MenuBarIconStyle.allCases.contains(.default))
    }

    // MARK: - Visibility policy

    func testStatusItemStaysVisibleWhenThePreferenceIsOff() {
        for hasExternal in [true, false] {
            for dock in [true, false] {
                XCTAssertTrue(
                    MenuBarIconPolicy.isStatusItemVisible(
                        hideWhenSingleDisplay: false, hasExternalDisplay: hasExternal, showDockIcon: dock
                    ),
                    "preference off must never hide (external=\(hasExternal), dock=\(dock))"
                )
            }
        }
    }

    func testStatusItemStaysVisibleWhileAnExternalDisplayIsAttached() {
        for dock in [true, false] {
            XCTAssertTrue(
                MenuBarIconPolicy.isStatusItemVisible(
                    hideWhenSingleDisplay: true, hasExternalDisplay: true, showDockIcon: dock
                )
            )
        }
    }

    func testStatusItemHidesOnlyWhenPreferenceIsOnSingleDisplayAndDockIconIsShown() {
        XCTAssertFalse(
            MenuBarIconPolicy.isStatusItemVisible(
                hideWhenSingleDisplay: true, hasExternalDisplay: false, showDockIcon: true
            )
        )
    }

    func testHideIsRefusedWithNoDockIconSoTheAppCannotBeStranded() {
        XCTAssertTrue(
            MenuBarIconPolicy.isStatusItemVisible(
                hideWhenSingleDisplay: true, hasExternalDisplay: false, showDockIcon: false
            )
        )
    }

    func testPolicyCoversEveryCombinationExactlyOnce() {
        // Table-driven so a future fourth parameter cannot silently escape the
        // cases above: the only hiding combination is the third argument set.
        var hiding: [[Bool]] = []
        for hide in [true, false] {
            for external in [true, false] {
                for dock in [true, false] {
                    let visible = MenuBarIconPolicy.isStatusItemVisible(
                        hideWhenSingleDisplay: hide, hasExternalDisplay: external, showDockIcon: dock
                    )
                    if !visible { hiding.append([hide, external, dock]) }
                }
            }
        }
        XCTAssertEqual(hiding, [[true, false, true]])
    }
}
