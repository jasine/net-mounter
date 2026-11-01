import Foundation

enum PasswordChange {
    case unchanged
    case replace(String)
    case remove
}

/// Stage the replacement first, commit the configuration, then clean up the old credential.
@MainActor
enum ServerConfigurationSaver {
    struct Outcome {
        let config: ServerConfig
        let credentialCleanupFailed: Bool
    }

    private enum SaveError: LocalizedError {
        case credentialWrite
        case rollbackCleanup(String)

        var errorDescription: String? {
            switch self {
            case .credentialWrite:
                return String(localized: "Could not save the password to Keychain. Your previous configuration and password are unchanged.", bundle: .module)
            case .rollbackCleanup(let reason):
                return reason + "\n" + String(localized: "The unused replacement password could not be removed from Keychain.", bundle: .module)
            }
        }
    }

    static func save(
        config: ServerConfig,
        passwordChange: PasswordChange,
        savePassword: (String, String) async -> String?,
        deletePassword: (String) async -> Bool,
        persist: (ServerConfig) -> Result<Void, Error>
    ) async -> Result<Outcome, Error> {
        var candidate = config
        let oldID = config.keychainItemId
        var stagedID: String?
        switch passwordChange {
        case .unchanged: break
        case .replace(let password):
            guard let id = await savePassword(password, UUID().uuidString) else {
                return .failure(SaveError.credentialWrite)
            }
            stagedID = id
            candidate.keychainItemId = id
        case .remove:
            candidate.keychainItemId = nil
        }

        switch persist(candidate) {
        case .failure(let error):
            if let stagedID, !(await deletePassword(stagedID)) {
                return .failure(SaveError.rollbackCleanup(error.localizedDescription))
            }
            return .failure(error)
        case .success:
            var cleanupFailed = false
            if let oldID, oldID != candidate.keychainItemId {
                cleanupFailed = !(await deletePassword(oldID))
            }
            return .success(Outcome(config: candidate, credentialCleanupFailed: cleanupFailed))
        }
    }
}
