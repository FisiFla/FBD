@testable import FBD
import FBDCore
import XCTest

@MainActor
final class PanelModelTests: XCTestCase {
    final class FakeToggles: QuickToggleBackend {
        var states: [QuickToggle.Kind: (Bool, Bool)] = [
            .darkMode: (true, true), .nightShift: (false, true),
            .trueTone: (false, false), .keepAwake: (false, true),
        ]
        var sets: [(QuickToggle.Kind, Bool)] = []
        func state(_ kind: QuickToggle.Kind) -> (isOn: Bool, isAvailable: Bool) {
            let s = states[kind]!; return (s.0, s.1)
        }
        func set(_ kind: QuickToggle.Kind, on: Bool) -> Bool {
            sets.append((kind, on)); states[kind] = (on, states[kind]!.1); return true
        }
    }

    private func makeModel(displays: [Display] = [], toggles: FakeToggles = FakeToggles()) -> PanelModel {
        PanelModel(displays: displays, toggleBackend: toggles, counts: { (2, 1) })
    }

    func testLiveGroupCountSeesGroupsCreatedElsewhere() {
        let suite = "PanelModelTests.groups.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PanelModel.liveGroupCount(defaults: defaults), 0)
        // GroupsPage owns its own controller; the count must still follow it.
        DisplayGroupsController(defaults: defaults).createGroup(name: "Desk")
        XCTAssertEqual(PanelModel.liveGroupCount(defaults: defaults), 1)
    }

    func testStartsAtHomeAndBackIsNoOpThere() {
        let m = makeModel()
        XCTAssertEqual(m.route, .home)
        m.back()
        XCTAssertEqual(m.route, .home)
    }

    func testAllModesBacksToItsDisplay() {
        XCTAssertEqual(PanelRoute.allModes(7).parent, .display(7))
        XCTAssertEqual(PanelRoute.display(7).parent, .home)
        XCTAssertEqual(PanelRoute.newPreset(7).parent, .home)
        XCTAssertNil(PanelRoute.home.parent)
    }

    func testEmptyDisplayListRendersHomeRoute() {
        let m = makeModel(displays: [])
        XCTAssertTrue(m.displays.isEmpty)
        XCTAssertEqual(m.route, .home)
        XCTAssertEqual(m.virtualScreenCount, 2)
        XCTAssertEqual(m.groupCount, 1)
    }

    func testRouteFallsBackWhenDisplayVanishes() {
        let m = makeModel(displays: [])
        m.open(.display(42))       // display unknown → refused
        XCTAssertEqual(m.route, .home)
    }

    func testUnavailableToggleIsDisabled() {
        let fake = FakeToggles()
        let m = makeModel(toggles: fake)
        let trueTone = m.toggles.first { $0.id == .trueTone }!
        XCTAssertFalse(trueTone.isAvailable)
        m.toggle(.trueTone)
        XCTAssertTrue(fake.sets.isEmpty, "an unavailable toggle must not be driven")
    }

    func testToggleFlipsAndRefreshes() {
        let fake = FakeToggles()
        let m = makeModel(toggles: fake)
        m.toggle(.nightShift)
        XCTAssertEqual(fake.sets.first?.0, .nightShift)
        XCTAssertEqual(fake.sets.first?.1, true)
        XCTAssertTrue(m.toggles.first { $0.id == .nightShift }!.isOn)
    }

    func testTogglesInSpecOrder() {
        XCTAssertEqual(makeModel().toggles.map(\.id), [.darkMode, .nightShift, .trueTone, .keepAwake])
    }

    func testNoDDCDisplayHidesVolume() {
        let m = makeModel()
        m.volumeAvailability[99] = false
        XCTAssertFalse(m.showsVolume(forID: 99))
        m.volumeAvailability[99] = true
        XCTAssertTrue(m.showsVolume(forID: 99))
        XCTAssertFalse(m.showsVolume(forID: 100), "unknown = not yet probed = hidden")
    }
}
