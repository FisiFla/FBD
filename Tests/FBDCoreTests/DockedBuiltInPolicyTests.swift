import CoreGraphics
import XCTest
@testable import FBDCore

/// The docked built-in display (#30): the built-in panel is turned off while
/// an external display is attached, so the user works on the external screen.
///
/// The decision itself is a pure function, so every branch is covered here;
/// the wiring around it is covered too, because the safety property — the
/// guard refuses *before* any SkyLight/CGS call goes out — is a property of
/// the wiring and not of the function.
final class DockedBuiltInPolicyTests: XCTestCase {
    private let suiteName = "test.fbd.docked"
    private var defaults: UserDefaults!

    /// The built-in panel and the external display, as the fake topology has
    /// them.
    private let builtinID: CGDirectDisplayID = 1
    private let externalID: CGDirectDisplayID = 2

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - The pure decision

    func testEverythingInOrderTurnsTheBuiltInOff() {
        let decision = DockedBuiltInPolicy.decide(
            settingEnabled: true,
            externalAttached: true,
            builtInEnabled: true,
            guardAllowsDisconnect: true
        )
        XCTAssertEqual(decision, .turnOff)
    }

    func testTheSettingOffKeepsTheBuiltInOn() {
        let decision = DockedBuiltInPolicy.decide(
            settingEnabled: false,
            externalAttached: true,
            builtInEnabled: true,
            guardAllowsDisconnect: true
        )
        XCTAssertEqual(decision, .keepOn(reason: .settingDisabled))
    }

    func testNoExternalAttachedKeepsTheBuiltInOn() {
        let decision = DockedBuiltInPolicy.decide(
            settingEnabled: true,
            externalAttached: false,
            builtInEnabled: true,
            guardAllowsDisconnect: true
        )
        XCTAssertEqual(decision, .keepOn(reason: .noExternalAttached))
    }

    /// A closed lid already switched the panel off, so there is nothing to do.
    func testABuiltInThatIsAlreadyOffIsLeftAlone() {
        let decision = DockedBuiltInPolicy.decide(
            settingEnabled: true,
            externalAttached: true,
            builtInEnabled: false,
            guardAllowsDisconnect: true
        )
        XCTAssertEqual(decision, .keepOn(reason: .builtInAlreadyOff))
    }

    /// The base-M3 case: the panel may not come back without a reboot, so the
    /// answer has to be "keep it on" — and the caller must not make a call.
    func testTheGuardRefusalKeepsTheBuiltInOn() {
        let decision = DockedBuiltInPolicy.decide(
            settingEnabled: true,
            externalAttached: true,
            builtInEnabled: true,
            guardAllowsDisconnect: false
        )
        XCTAssertEqual(decision, .keepOn(reason: .guardRefused))
    }

    /// The guard is the last word: it refuses even when everything else says
    /// the panel could go off.
    func testTheGuardRefusalWinsOverEverythingElse() {
        let decision = DockedBuiltInPolicy.decide(
            settingEnabled: true,
            externalAttached: true,
            builtInEnabled: true,
            guardAllowsDisconnect: false
        )
        if case .turnOff = decision {
            XCTFail("the guard must win")
        }
    }

    // MARK: - The setting

    /// Turning a panel off without being asked is never silent.
    func testTheSettingIsOffByDefault() throws {
        let key = "dockedBuiltInOffEnabled"
        guard Settings.defaults.object(forKey: key) == nil else {
            throw XCTSkip("\(key) already written in this defaults domain")
        }
        XCTAssertFalse(Settings.dockedBuiltInOffEnabled)
    }

    // MARK: - The wiring

    /// A topology with the built-in panel on and an external display attached.
    private func makeTopology() -> FakeDisplayTopology {
        let topology = FakeDisplayTopology()
        topology.builtin = builtinID
        topology.online = [builtinID: "1-1-1", externalID: "2-2-2"]
        topology.active = [builtinID, externalID]
        return topology
    }

    /// A controller with the policies presented as the test needs them.
    private func makeController(
        topology: FakeDisplayTopology,
        enabler: RecordingDisplayEnabler,
        docked: Bool = true,
        autoDisconnectOnExternal: Bool = false,
        guardAllows: Bool = true
    ) -> DisconnectController {
        let controller = DisconnectController(defaults: defaults, topology: topology, enabler: enabler)
        controller.dockedBuiltInOffEnabled = { docked }
        controller.autoDisconnectBuiltInOnExternal = { autoDisconnectOnExternal }
        controller.allowsBuiltInDisconnect = { guardAllows }
        return controller
    }

    func testAnAttachedExternalDisplayTurnsTheBuiltInOff() {
        let enabler = RecordingDisplayEnabler()
        makeController(topology: makeTopology(), enabler: enabler).evaluateBuiltInDisplay()

        XCTAssertEqual(enabler.calls.count, 1)
        XCTAssertEqual(enabler.calls.first?.displayID, builtinID)
        XCTAssertEqual(enabler.calls.first?.enabled, false)
    }

    /// The safety property: on a base-M3 MacBook the panel may not come back
    /// without a reboot, so **no call is made at all** — not a call that is
    /// then refused, but no call.
    func testTheGuardRefusalMakesNoCallAtAll() {
        let enabler = RecordingDisplayEnabler()
        makeController(topology: makeTopology(), enabler: enabler, guardAllows: false)
            .evaluateBuiltInDisplay()

        XCTAssertTrue(enabler.calls.isEmpty, "the guard must short-circuit before any call")
    }

    func testTheSettingOffMakesNoCallAtAll() {
        let enabler = RecordingDisplayEnabler()
        makeController(topology: makeTopology(), enabler: enabler, docked: false)
            .evaluateBuiltInDisplay()

        XCTAssertTrue(enabler.calls.isEmpty)
    }

    func testWithoutAnExternalDisplayNothingHappens() {
        let topology = makeTopology()
        topology.online = [builtinID: "1-1-1"]
        topology.active = [builtinID]
        let enabler = RecordingDisplayEnabler()
        makeController(topology: topology, enabler: enabler).evaluateBuiltInDisplay()

        XCTAssertTrue(enabler.calls.isEmpty)
    }

    /// An external display that is attached but *not* active still counts: the
    /// docked policy keys on attachment, not on activity — the existing
    /// auto-disconnect policy is the one that keys on activity.
    func testAnAttachedButIdleExternalDisplayStillCounts() {
        let topology = makeTopology()
        topology.active = [builtinID]
        let enabler = RecordingDisplayEnabler()
        makeController(topology: topology, enabler: enabler).evaluateBuiltInDisplay()

        XCTAssertEqual(enabler.calls.count, 1)
        XCTAssertEqual(enabler.calls.first?.displayID, builtinID)
    }

    // MARK: - The two built-in policies do not fight

    /// The docked policy wants the built-in off while an external display is
    /// attached; the auto-disconnect policy wants it off while an external
    /// display is *active*. With an idle external attached, only the docked
    /// policy wants it off — and it must not be switched back on by the other
    /// one.
    func testTheDockedPolicyKeepsTheBuiltInOffWhenTheExternalIsIdle() {
        let topology = makeTopology()
        topology.active = [builtinID]
        let enabler = RecordingDisplayEnabler()
        let controller = makeController(
            topology: topology,
            enabler: enabler,
            docked: true,
            autoDisconnectOnExternal: true
        )

        controller.evaluateBuiltInDisplay()
        XCTAssertEqual(enabler.calls.count, 1)
        XCTAssertEqual(enabler.calls.first?.enabled, false)

        // The next evaluation must not undo it.
        controller.evaluateBuiltInDisplay()
        XCTAssertEqual(enabler.calls.count, 1, "the built-in display must stay off")
    }

    /// The other way round: the auto-disconnect policy alone still works.
    func testTheAutoDisconnectPolicyStillTurnsTheBuiltInOff() {
        let enabler = RecordingDisplayEnabler()
        makeController(
            topology: makeTopology(),
            enabler: enabler,
            docked: false,
            autoDisconnectOnExternal: true
        ).evaluateBuiltInDisplay()

        XCTAssertEqual(enabler.calls.count, 1)
        XCTAssertEqual(enabler.calls.first?.displayID, builtinID)
    }

    /// With neither policy wanting it off, a built-in display FBD turned off
    /// earlier is brought back.
    func testTheBuiltInDisplayComesBackWhenNoPolicyWantsItOff() {
        let enabler = RecordingDisplayEnabler()
        let controller = makeController(
            topology: makeTopology(),
            enabler: enabler,
            docked: true,
            autoDisconnectOnExternal: false
        )
        // The first evaluation turns it off.
        controller.evaluateBuiltInDisplay()
        XCTAssertEqual(enabler.calls.count, 1)

        // The external display is gone: nothing wants the built-in off any
        // more, so it comes back.
        let topology = makeTopology()
        topology.online = [builtinID: "1-1-1"]
        topology.active = [builtinID]
        let returning = makeController(topology: topology, enabler: enabler, docked: true)
        returning.builtInDisabledByUs = true
        returning.evaluateBuiltInDisplay()

        XCTAssertEqual(enabler.calls.count, 2)
        XCTAssertEqual(enabler.calls.last?.enabled, true, "the built-in display must come back")
    }
}
