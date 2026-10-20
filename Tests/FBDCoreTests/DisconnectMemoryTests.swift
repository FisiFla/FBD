import CoreGraphics
import XCTest
@testable import FBDCore

/// The remembered disconnects (#30): a disconnect is a **setting**, not an
/// event.
///
/// The store, the topology and the enable/disable action are all injected, so
/// the whole behaviour — including "it survives a restart" — is provable
/// without a display attached.
final class DisconnectMemoryTests: XCTestCase {
    private let suiteName = "test.fbd.disconnect.memory"
    private var defaults: UserDefaults!

    /// A display id no Mac has.
    private let externalID: CGDirectDisplayID = 4242

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

    /// The identity key the fake display's settings are filed under — the same
    /// key `Display.identityKey` builds, under the identity method in force.
    private var identity: String {
        DisplayIdentity.key(
            vendor: 1234,
            model: 5678,
            serial: 9,
            name: "Desk display",
            method: Settings.displayIdentityMethod
        )
    }

    /// The display the tests remember and re-disconnect.
    private func makeDisplay() -> Display {
        Display(
            id: externalID,
            name: "Desk display",
            isBuiltin: false,
            vendorNumber: 1234,
            modelNumber: 5678,
            serialNumber: 9,
            bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            isOnline: true,
            isActive: true
        )
    }

    /// A controller with a fake topology and a recording action.
    private func makeController(
        topology: FakeDisplayTopology = FakeDisplayTopology(),
        enabler: RecordingDisplayEnabler = RecordingDisplayEnabler()
    ) -> DisconnectController {
        DisconnectController(defaults: defaults, topology: topology, enabler: enabler)
    }

    // MARK: - The store

    func testNothingIsRememberedByDefault() {
        let store = UserDefaultsDisconnectMemoryStore(defaults: defaults)
        XCTAssertFalse(store.isRemembered(identity))
        XCTAssertTrue(store.rememberedIdentities().isEmpty)
    }

    func testTheStoreRemembersAndForgets() {
        let store = UserDefaultsDisconnectMemoryStore(defaults: defaults)
        store.remember(identity)
        XCTAssertTrue(store.isRemembered(identity))
        store.forget(identity)
        XCTAssertFalse(store.isRemembered(identity))
    }

    func testTheStoreListsWhatItRemembers() {
        let store = UserDefaultsDisconnectMemoryStore(defaults: defaults)
        store.remember("first")
        store.remember("second")
        XCTAssertEqual(store.rememberedIdentities(), ["first", "second"])
    }

    /// The stored form: a JSON value under a per-display key, like every other
    /// per-display setting in the app.
    func testTheValueIsStoredAsJSONUnderAPerDisplayKey() {
        let store = UserDefaultsDisconnectMemoryStore(defaults: defaults)
        store.remember(identity)

        let data = defaults.data(forKey: "disconnectMemory.\(identity)")
        XCTAssertNotNil(data, "the value must be stored under a per-display key")
        XCTAssertEqual(try? JSONDecoder().decode(Bool.self, from: data!), true)
    }

    func testForgettingRemovesTheStoredValue() {
        let store = UserDefaultsDisconnectMemoryStore(defaults: defaults)
        store.remember(identity)
        store.forget(identity)
        XCTAssertNil(defaults.object(forKey: "disconnectMemory.\(identity)"))
    }

    // MARK: - The controller

    /// The point of the feature: a disconnect is a setting, so it has to
    /// outlive the process that made it.
    func testARememberedDisconnectSurvivesARestart() {
        let first = makeController()
        first.rememberDisconnect(for: makeDisplay())

        // "Restart": a new controller over a new store on the same defaults.
        let second = makeController()
        XCTAssertTrue(second.isDisconnectRemembered(for: makeDisplay()))
    }

    func testForgettingSurvivesARestartToo() {
        let first = makeController()
        first.rememberDisconnect(for: makeDisplay())
        first.forgetDisconnect(for: makeDisplay())

        let second = makeController()
        XCTAssertFalse(second.isDisconnectRemembered(for: makeDisplay()))
    }

    // MARK: - Re-applying the disconnects

    func testARememberedDisplayIsDisconnectedAgainWhenItComesBack() {
        let topology = FakeDisplayTopology()
        topology.online = [externalID: identity]
        let enabler = RecordingDisplayEnabler()
        let controller = makeController(topology: topology, enabler: enabler)
        controller.rememberDisconnect(for: makeDisplay())

        controller.evaluateRememberedDisconnects()

        XCTAssertEqual(enabler.calls.count, 1)
        XCTAssertEqual(enabler.calls.first?.displayID, externalID)
        XCTAssertEqual(enabler.calls.first?.enabled, false, "the display must be turned off again")
    }

    func testADisplayThatIsNotRememberedIsLeftAlone() {
        let topology = FakeDisplayTopology()
        topology.online = [externalID: identity]
        let enabler = RecordingDisplayEnabler()
        let controller = makeController(topology: topology, enabler: enabler)

        controller.evaluateRememberedDisconnects()

        XCTAssertTrue(enabler.calls.isEmpty, "a display nobody remembered must not be touched")
    }

    /// A display that was already online is not "back": FBD must not fight the
    /// user over a screen they have just re-enabled.
    func testADisplayThatWasAlreadyOnlineIsNotDisconnectedAgain() {
        let topology = FakeDisplayTopology()
        topology.online = [externalID: identity]
        let enabler = RecordingDisplayEnabler()
        let controller = makeController(topology: topology, enabler: enabler)
        controller.rememberDisconnect(for: makeDisplay())

        controller.evaluateRememberedDisconnects()
        let afterFirst = enabler.calls.count
        controller.evaluateRememberedDisconnects()

        XCTAssertEqual(afterFirst, 1)
        XCTAssertEqual(enabler.calls.count, 1, "the display was already there — it did not come back")
    }

    /// The display comes back after being unplugged: it is offline in between,
    /// so the next evaluation sees it as new.
    func testADisplayThatWasUnpluggedAndPluggedBackInIsDisconnectedAgain() {
        let topology = FakeDisplayTopology()
        topology.online = [externalID: identity]
        let enabler = RecordingDisplayEnabler()
        let controller = makeController(topology: topology, enabler: enabler)
        controller.rememberDisconnect(for: makeDisplay())

        controller.evaluateRememberedDisconnects()
        // Unplugged: the display is gone.
        topology.online = [:]
        controller.evaluateRememberedDisconnects()
        // Plugged back in.
        topology.online = [externalID: identity]
        controller.evaluateRememberedDisconnects()

        XCTAssertEqual(enabler.calls.count, 2, "the second time it comes back it must be turned off again")
        XCTAssertTrue(enabler.calls.allSatisfy { !$0.enabled })
    }

    /// "until the user re-enables it": re-enabling the display ends the
    /// request, so the next replug leaves it alone.
    func testReEnablingTheDisplayForgetsTheRequest() {
        let topology = FakeDisplayTopology()
        topology.online = [externalID: identity]
        let enabler = RecordingDisplayEnabler()
        let controller = makeController(topology: topology, enabler: enabler)
        controller.rememberDisconnect(for: makeDisplay())

        // The real enable path: the CGS call fails for a display that does not
        // exist, but the request is dropped before it is made.
        _ = controller.setEnabled(true, displayID: externalID)

        XCTAssertFalse(controller.isDisconnectRemembered(for: makeDisplay()))
        controller.evaluateRememberedDisconnects()
        XCTAssertTrue(enabler.calls.isEmpty, "the user re-enabled it — it must stay on")
    }
}
