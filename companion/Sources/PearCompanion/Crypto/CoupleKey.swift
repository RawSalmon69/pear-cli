import Foundation
import Security
import CryptoKit

/// The couple's shared secret and this Mac's role, both stored in the login
/// Keychain. Owner sets the key on both Macs once during setup; a missing key
/// puts messaging in the `.needsSetup` state.
enum CoupleKey {
    static let service = "com.rawsalmon69.pear.companion"
    static let keyAccount = "couple-key"
    static let roleAccount = "device-role"

    /// A fresh base64 256-bit key. Printed by the setup guide / a `pear`
    /// one-liner and pasted into the Keychain on both Macs.
    static func generate() -> String {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        return data.base64EncodedString()
    }

    /// The shared key if one is configured and well-formed, else nil.
    static func load() -> SymmetricKey? {
        guard
            let base64 = read(account: keyAccount),
            let data = Data(base64Encoded: base64),
            data.count == 32
        else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    @discardableResult
    static func store(base64Key: String) -> Bool {
        guard let data = Data(base64Encoded: base64Key), data.count == 32 else {
            return false
        }
        return write(account: keyAccount, value: base64Key)
    }

    static var isConfigured: Bool {
        load() != nil
    }

    @discardableResult
    static func store(role: String) -> Bool {
        write(account: roleAccount, value: role)
    }

    /// This Mac's role ("raws" / "pear"), falling back to the hostname so
    /// sender attribution still works before setup sets a role.
    static var deviceRole: String {
        if let role = read(account: roleAccount), !role.isEmpty {
            return role
        }
        return Host.current().localizedName ?? "mac"
    }

    // MARK: - Keychain (generic password items)

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard
            status == errSecSuccess,
            let data = item as? Data,
            let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    @discardableResult
    private static func write(account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
