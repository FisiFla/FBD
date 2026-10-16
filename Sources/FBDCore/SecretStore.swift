import Foundation
import Security

/// Storage for small secrets (API token, TV pairing key). Behind a protocol so
/// tests never touch the real login keychain.
protocol SecretStore {
    /// nil when absent or unreadable.
    func read(account: String) -> String?
    @discardableResult
    func write(_ value: String, account: String) -> Bool
    func delete(account: String)
}

/// Generic-password Keychain items, shared by the app and fbdcli via a fixed
/// service name. Items are this-device-only and readable after first unlock.
/// Legacy (file-based) keychain: the data-protection keychain needs a
/// keychain-access-groups entitlement that ad-hoc signed binaries lack.
struct KeychainSecretStore: SecretStore {
    static let service = "dev.fisifla.fbd"

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(
            query(account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
