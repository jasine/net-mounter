import Foundation
import Security
import Logging

private let logger = Logger(label: "KeychainManager")

class KeychainManager {
    static let shared = KeychainManager()
    
    // Service name for our app
    private let service = "com.netmounter.service"
    
    func save(password: String, for account: String) -> String? {
        let diagnostic = DiagnosticsService.shared.begin(.keychainSave)
        let passwordData = password.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData
        ]
        
        // Replacement passwords are staged under a new account ID. Never delete an old item here.
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        
        diagnostic.finish(error: status == errSecSuccess ? nil : ReadError.status(status))
        if status == errSecSuccess {
            return account // Return the account name as the ID/reference
        } else {
            logger.error("Error saving to keychain: \(status)")
            return nil
        }
    }
    
    enum ReadError: Error, Equatable {
        case status(OSStatus)
    }

    /// Injectable read only; tests never access the user's Keychain.
    var copyPasswordItem: ((CFDictionary) -> (OSStatus, AnyObject?))?

    func readPassword(for account: String) -> Result<String, ReadError> {
        let diagnostic = DiagnosticsService.shared.begin(.keychainRead)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let status: OSStatus
        let item: AnyObject?
        if let copyPasswordItem {
            (status, item) = copyPasswordItem(query as CFDictionary)
        } else {
            var result: AnyObject?
            status = SecItemCopyMatching(query as CFDictionary, &result)
            item = result
        }
        guard status == errSecSuccess else {
            diagnostic.finish(error: ReadError.status(status))
            return .failure(.status(status))
        }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            diagnostic.finish(error: ReadError.status(errSecDecode))
            return .failure(.status(errSecDecode))
        }
        diagnostic.finish()
        return .success(password)
    }

    @discardableResult
    func delete(account: String) -> Bool {
        let diagnostic = DiagnosticsService.shared.begin(.keychainDelete)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        diagnostic.finish(error: status == errSecSuccess || status == errSecItemNotFound ? nil : ReadError.status(status))
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Error deleting from keychain: \(status)")
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
