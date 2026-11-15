import CryptoKit
import Foundation
import Security

/// Approval seals for automation rules.
///
/// Rules live in UserDefaults, which any process running as the user can
/// write. Without a seal, planting a rule there would be enough to have FBD
/// run a command on the next display or sleep event. A rule therefore fires on
/// its event only when it carries an HMAC made with a key that lives in the
/// login Keychain — and only the app makes one, when the user adds or approves
/// the rule in Settings. `fbdcli` never reads the key: a rule it adds waits for
/// approval in the app.
///
/// Fails closed: no key, no seal or a seal that does not verify all mean
/// "not approved".
enum AutomationSeal {
    static let account = "automationSealKey"

    /// What an approval covers: everything that decides what runs and when.
    /// `enabled` is left out, so switching an approved rule off and on again
    /// does not need a second approval.
    static func message(for rule: AutomationRule) -> Data {
        let fields = [
            rule.id.uuidString,
            rule.displayIdentityKey,
            rule.event.token,
            rule.kind.token,
            rule.payload,
        ]
        // Length-prefixed, so no two field lists share an encoding.
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            data.append(Data("\(bytes.count):".utf8))
            data.append(bytes)
        }
        return data
    }

    static func seal(_ rule: AutomationRule, key: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: message(for: rule), using: SymmetricKey(data: key))
        return Data(code).base64EncodedString()
    }

    static func isValid(_ seal: String?, for rule: AutomationRule, key: Data?) -> Bool {
        guard let seal, let key, let code = Data(base64Encoded: seal) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            code,
            authenticating: message(for: rule),
            using: SymmetricKey(data: key)
        )
    }

    /// The rules that may fire on an event: those whose stored seal verifies.
    static func approved(_ rules: [AutomationRule], seals: [String: String], key: Data?) -> [AutomationRule] {
        rules.filter { isValid(seals[$0.id.uuidString], for: $0, key: key) }
    }

    /// The sealing key, or nil when there is none (or it cannot be read).
    /// `create` makes one on first use — the app's approval path only.
    ///
    /// Blocks while the Keychain asks the user for access, so event-driven
    /// callers stay off the main actor.
    static func key(store: SecretStore, create: Bool) -> Data? {
        if let stored = store.read(account: account),
           let key = Data(base64Encoded: stored), key.count == 32 {
            return key
        }
        guard create else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let key = Data(bytes)
        guard store.write(key.base64EncodedString(), account: account) else { return nil }
        return key
    }
}
