import Foundation
import Network
import Security

struct DiagnosticFailure {
    let family: String
    let code: Int
    let expected: Bool

    init(_ error: Error) {
        expected = Self.isExpected(error)
        switch error {
        case let error as MountError:
            switch error {
            case .mountFailed(let value): family = "mount"; code = Int(value)
            case .invalidURL: family = "invalid_url"; code = 0
            case .invalidShare: family = "invalid_share"; code = 0
            case .timedOut: family = "timeout"; code = 0
            case .keychainReadFailed(let value): family = "keychain"; code = Int(value)
            case .cancellationFailed(let value): family = "cancellation"; code = Int(value)
            case .authenticationRequired: family = "authentication_required"; code = 0
            case .authenticationFailed: family = "authentication_failed"; code = 0
            }
        case let error as KeychainManager.ReadError:
            switch error { case .status(let value): family = "keychain"; code = Int(value) }
        case let error as ConnectionError:
            switch error {
            case .timeout: family = "timeout"; code = 0
            case .cancelled: family = "cancelled"; code = 0
            case .connectionFailed: family = "connection"; code = 0
            }
        case let error as WOLError:
            switch error {
            case .invalidMACAddress: family = "invalid_mac"; code = 0
            case .sendFailed: family = "wol_send"; code = 0
            }
        case let error as NWError:
            switch error {
            case .posix(let value): family = "posix"; code = Int(value.rawValue)
            case .dns(let value): family = "dns"; code = Int(value)
            case .tls(let value): family = "tls"; code = Int(value)
            default: family = "network"; code = 0
            }
        default:
            let nsError = error as NSError
            // The domain and localizedDescription can contain hosts, paths or credentials.
            switch nsError.domain {
            case NSCocoaErrorDomain: family = "cocoa"
            case NSPOSIXErrorDomain: family = "posix"
            case NSOSStatusErrorDomain: family = "osstatus"
            case NSURLErrorDomain: family = "url"
            default: family = "other"
            }
            code = nsError.code
        }
    }

    private static func isExpected(_ error: Error) -> Bool {
        if let error = error as? MountError, error == .mountFailed(EBUSY) { return true }
        if let error = error as? ConnectionError, case .cancelled = error { return true }
        if let error = error as? KeychainManager.ReadError,
           case .status(let status) = error, status == errSecUserCanceled { return true }
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError)
            || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
    }

    static let families: Set<String> = [
        "mount", "invalid_url", "invalid_share", "timeout", "keychain", "cancellation",
        "authentication_required", "authentication_failed", "cancelled", "connection",
        "invalid_mac", "wol_send", "posix", "dns", "tls", "network", "cocoa", "osstatus", "url", "other"
    ]
}
